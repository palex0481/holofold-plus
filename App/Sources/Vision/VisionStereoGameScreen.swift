#if os(visionOS)
import AzaharCore
import GameController
import RealityKit
import SwiftUI

/// Window ids of the stereo game (VisionGameScenes declares them). The touch window always
/// carries the same value, so opening it again focuses the existing window instead of adding
/// another one.
enum VisionWindowID {
    /// The public build's boot window (picks the game, then closes; see MinimalApp).
    static let boot = "holofold-boot"
    /// The top screen, in stereo, filling a plain 5:3 window.
    static let game = "holofold-game"
    /// The bottom screen in its own small window, placed under the game window.
    static let touch = "holofold-touch"
    static let touchValue = "touch"
}

/// What the game window should run.
struct VisionGameRequest: Codable, Hashable {
    let gameID: String
    /// Restore the auto-save (slot 0) once the game is running.
    var resume = false
}

/// Slot 0 is the auto-save written when the player leaves a game (Azahar reserves no other use).
enum VisionAutoSave {
    static let slot = 0

    /// Its file: Documents/Azahar/states/<title id>.00.cst (Azahar's GetSaveStatePath).
    static func url(for game: Game) -> URL {
        EmulatorCore.shared.userDirectory.appendingPathComponent("states", isDirectory: true)
            .appendingPathComponent(String(format: "%@.%02d.cst", game.titleIDString, slot))
    }

    static func date(for game: Game) -> Date? {
        guard game.supportsSaveStates else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url(for: game).path))?[.modificationDate] as? Date
    }
}

enum VisionStereo {
    static let enabledKey = "visionStereoEnabled"
    static let depthKey = "visionStereoDepth"
    static let defaultDepth = 100
    /// Bottom screen tilt, top edge away from the player, like a 3DS's lower half.
    static let touchTiltDegrees: Float = 22
    /// Curved top screen (CitraVR's cylinder mode): on/off and the arc's central angle.
    static let curvedKey = "visionCurvedScreen"
    static let curveKey = "visionCurveDegrees"
    static let defaultCurve = 50
    static let curveRange = 20...90
}

/// One running game, shared by the game window and the touch window: the frame source, the two
/// panels and their material. Created when the game window opens, dropped when it closes.
@MainActor
final class VisionGameSession: ObservableObject {
    static private(set) var current: VisionGameSession?

    let game: Game
    let source: StereoFrameSource
    let top = ModelEntity()
    let bottom = ModelEntity()
    private var material: ShaderGraphMaterial?
    private var materialTask: Task<Void, Never>?
    private var subscription: EventSubscription?
    private var topShape: (width: Float, height: Float, curve: Float) = (0, 0, -1)
    private var bottomSize: (width: Float, height: Float) = (0, 0)
    private var sources: (top: StereoFrameSource.Source?, bottom: StereoFrameSource.Source?)

    static func begin(_ game: Game) -> VisionGameSession {
        if let current, current.game.id == game.id { return current }
        let session = VisionGameSession(game: game)
        current = session
        return session
    }

    private init(game: Game) {
        self.game = game
        // Eye halves at the internal resolution: portrait layout is 400 × 480 (top over bottom).
        let scale = max(1, min(AppSettings.shared.resolutionFactor, 6))
        source = StereoFrameSource(eyeWidth: 400 * scale, eyeHeight: 480 * scale)
        bottom.components.set(InputTargetComponent())
        materialTask = Task { [weak self] in
            do {
                let loaded = try await ShaderGraphMaterial(named: "/Root/StereoScreen", from: "StereoScreen", in: .main)
                self?.material = loaded
                self?.applyAll()
            } catch {
                NSLog("Holofold stereo: cannot load StereoScreen material: %@", "\(error)")
            }
        }
        source.onSources = { [weak self] top, bottom in
            self?.sources = (top, bottom)
            self?.applyAll()
        }
    }

    /// The game window's RealityView drives the frame pump.
    func startPumping(in content: RealityViewContent) {
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.source.pump() }
        }
    }

    /// Stops the running game, saving it to the auto-save slot first. The save is a request the
    /// emulation thread handles on its next frame, so this waits (up to 3 s) for the file to change
    /// before stopping. Safe to call more than once.
    static func stopGame(autosave: Bool) async {
        let core = EmulatorCore.shared
        guard az_is_running() else { core.stop(); return }
        if autosave, let game = current?.game, game.supportsSaveStates {
            let before = VisionAutoSave.date(for: game)
            core.saveState(slot: VisionAutoSave.slot)
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if let now = VisionAutoSave.date(for: game), now != before { break }
            }
            VisionDiag.log("autosave \(VisionAutoSave.date(for: game) != before ? "written" : "timed out") for \(game.titleIDString)")
        }
        core.stop()
        for _ in 0..<50 where az_is_running() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func end() {
        subscription?.cancel()
        subscription = nil
        materialTask?.cancel()
        source.onSources = nil
        source.detach()
        if Self.current === self { Self.current = nil }
    }

    // MARK: Layout

    /// Top screen (5:3) as large as the window allows: flat, or bent into an arc of `curveDegrees`.
    func layoutTop(width: Float, height: Float, curveDegrees: Float) {
        guard width > 0, height > 0 else { return }
        // A curved screen's edges come toward the player and look larger, so it gets a margin;
        // spilling onto the touch window below would make visionOS show this window translucent.
        let fill: Float = curveDegrees > 0 ? 0.88 : 1
        let w = min(width, height * 5 / 3) * fill, h = w * 0.6
        guard (w, h, curveDegrees) != topShape else { return }
        topShape = (w, h, curveDegrees)
        let mesh: MeshResource
        if curveDegrees > 0, let curved = Self.curvedScreen(chord: w, height: h, degrees: curveDegrees) {
            mesh = curved
        } else {
            mesh = .generatePlane(width: w, height: h)
        }
        top.model = ModelComponent(mesh: mesh, materials: top.model?.materials ?? [UnlitMaterial(color: .black)])
    }

    /// A screen bent around a vertical cylinder whose axis is on the viewer's side, so the left and
    /// right edges come toward the player (CitraVR's "extends the top screen around a cylinder").
    /// The chord, not the arc, equals `chord`, so the curved screen still spans the window; the
    /// edges come forward by the arc's sagitta. UVs: u left→right, v bottom→top, which with the
    /// material's sampling shows the image upright (as generatePlane does; checked in the Simulator).
    static func curvedScreen(chord: Float, height: Float, degrees: Float, segments: Int = 48) -> MeshResource? {
        let angle = degrees * .pi / 180
        let radius = (chord / 2) / sin(angle / 2)
        let sagitta = radius * (1 - cos(angle / 2))
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for i in 0...segments {
            let t = Float(i) / Float(segments)
            let phi = (t - 0.5) * angle
            // Centre plane of the arc at z = 0 at the middle; edges move forward by up to the sagitta,
            // then shift everything back by half of it so the screen straddles the window plane.
            let x = radius * sin(phi)
            let z = radius * (1 - cos(phi)) - sagitta / 2
            let normal = SIMD3<Float>(-sin(phi), 0, cos(phi))
            positions.append([x, height / 2, z]); normals.append(normal); uvs.append([t, 1])
            positions.append([x, -height / 2, z]); normals.append(normal); uvs.append([t, 0])
        }
        var indices: [UInt32] = []
        for i in 0..<UInt32(segments) {
            let top0 = i * 2, bottom0 = i * 2 + 1, top1 = i * 2 + 2, bottom1 = i * 2 + 3
            indices += [bottom0, bottom1, top1, bottom0, top1, top0] // counter-clockwise seen from the front
        }
        var descriptor = MeshDescriptor(name: "curvedScreen")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Bottom screen (4:3) as large as its window allows, tilted top-away.
    func layoutBottom(width: Float, height: Float) {
        guard width > 0, height > 0 else { return }
        let w = min(width, height * 4 / 3), h = w * 0.75
        guard (w, h) != bottomSize else { return }
        bottomSize = (w, h)
        bottom.model = ModelComponent(mesh: .generatePlane(width: w, height: h),
                                      materials: bottom.model?.materials ?? [UnlitMaterial(color: .black)])
        bottom.components.set(CollisionComponent(shapes: [.generateBox(width: w, height: h, depth: 0.004)]))
        let tilt = VisionStereo.touchTiltDegrees * .pi / 180
        bottom.orientation = simd_quatf(angle: -tilt, axis: [1, 0, 0])
    }

    /// Panel-local point → bottom screen pixel (surface coordinates), or nil outside the panel.
    func touchPoint(_ local: SIMD3<Float>) -> CGPoint? {
        guard let rect = source.bottomPixelRect, bottomSize.width > 0 else { return nil }
        let u = CGFloat(local.x / bottomSize.width + 0.5)
        let v = CGFloat(0.5 - local.y / bottomSize.height)
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: rect.minX + u * rect.width, y: rect.minY + v * rect.height)
    }

    // MARK: Materials

    private func applyAll() {
        apply(sources.top, to: top)
        apply(sources.bottom, to: bottom)
    }

    /// The panel's UV (v = 1 at the top edge) maps to uv * scale + offset, and RealityKit then
    /// samples the image at 1 − y (rows counted from the top). So for a screen rect in image space
    /// the offset is (minX, 1 − maxY). A whole-texture rect cannot tell the two conventions apart,
    /// which is why the Simulator (software frames, one texture per screen) looked right while the
    /// device's stereo frame showed the bottom screen on the top panel.
    private func apply(_ src: StereoFrameSource.Source?, to entity: ModelEntity) {
        guard let src, var material else { return }
        do {
            try material.setParameter(name: "Texture", value: .textureResource(src.texture))
            try material.setParameter(name: "Scale", value: .simd2Float([Float(src.left.width), Float(src.left.height)]))
            try material.setParameter(name: "LeftOffset", value: .simd2Float([Float(src.left.minX), Float(1 - src.left.maxY)]))
            try material.setParameter(name: "RightOffset", value: .simd2Float([Float(src.right.minX), Float(1 - src.right.maxY)]))
            entity.model?.materials = [material]
        } catch {
            NSLog("Holofold stereo: material parameter failed: %@", "\(error)")
        }
    }
}

// MARK: - Game window (top screen)

/// The top screen filling its window, in stereo. Owns the emulation session: opening the
/// window boots the game and opens the touch window; leaving the game auto-saves, stops it and
/// closes both windows, and the launcher comes back. Pause / 3D depth / exit sit in an ornament.
///
/// Leaving can start in the background (Digital Crown → Home View), where dismissing windows is
/// unreliable, so the windows only close once the app is active again (`pendingClose`).
struct VisionGameWindow: View {
    let request: VisionGameRequest

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var core = EmulatorCore.shared
    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var keyboard = VisionKeyboard.shared
    @State private var keyboardText = ""
    @AppStorage(VisionStereo.depthKey) private var depth = VisionStereo.defaultDepth
    @AppStorage(VisionStereo.curvedKey) private var curved = true
    @AppStorage(VisionStereo.curveKey) private var curve = VisionStereo.defaultCurve
    @State private var session: VisionGameSession?
    @State private var started = false
    @State private var exiting = false
    @State private var pendingClose = false
    @State private var closed = false
    @State private var resumed = false
    /// Paused because the window became inactive (not by the player); resumed when it is active.
    @State private var pausedByPhase = false

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                guard let session else { return }
                content.add(session.top)
                session.startPumping(in: content)
            } update: { content in
                guard let session else { return }
                let bounds = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                session.layoutTop(width: bounds.extents.x, height: bounds.extents.y,
                                  curveDegrees: curved ? Float(curve) : 0)
            }
            .id(session.map { ObjectIdentifier($0) })
            .overlay {
                if exiting {
                    statusCard("Saving and exiting…")
                } else if case .loading(let stage, _) = core.state {
                    statusCard(stage < 4 ? "Loading game…" : "Starting…")
                }
            }
        }
        // Above the window and pulled toward the player: the curved screen's corners come forward
        // past the window plane and hid a bar that sat on it (device screenshot).
        .ornament(attachmentAnchor: .scene(UnitPoint(x: 0.5, y: -0.12)), contentAlignment: .bottom) {
            controls.offset(z: 140)
        }
        .background(GameControllerCapture())
        .onAppear(perform: start)
        .onDisappear(perform: finish)
        .onChange(of: scenePhase) { _, phase in
            VisionDiag.log("game window scene: \(phase)")
            switch phase {
            case .background:
                // Digital Crown → Home View, or the headset went to sleep.
                VisionDiag.log("exit: scene went to background")
                requestExit()
            case .inactive:
                // Briefly not in front (system UI, Control Center …): pause, and resume when the
                // window is active again. Not resuming here looked exactly like a frozen game.
                if core.state == .running {
                    pausedByPhase = true
                    core.setPaused(true)
                }
            case .active:
                if pendingClose { closeWindows() }
                if pausedByPhase {
                    pausedByPhase = false
                    if core.state == .paused { core.setPaused(false) }
                }
            @unknown default:
                break
            }
        }
        // Options held on a controller (the PS button itself is the system's).
        .onReceive(NotificationCenter.default.publisher(for: .bifoldExitGame)) { _ in requestExit() }
        .onChange(of: core.state) { _, state in
            switch state {
            case .idle where started:
                if scenePhase == .active { closeWindows() } else { pendingClose = true }
            #if DEBUG
            // -autoExitAfter <s>: leave the game by itself once it runs (exit / window checks).
            case .running where UserDefaults.standard.double(forKey: "autoExitAfter") > 0 && !resumed && !request.resume:
                resumed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + UserDefaults.standard.double(forKey: "autoExitAfter")) {
                    NotificationCenter.default.post(name: .bifoldExitGame, object: nil)
                }
            #endif
            case .running where request.resume && !resumed:
                resumed = true
                // Give the game a moment to settle before replacing its state, as the iOS screen does.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { core.loadState(slot: VisionAutoSave.slot) }
            default:
                break
            }
        }
        // The 3DS software keyboard (name entry and the like). The game waits until it's answered.
        .alert(keyboard.prompt?.hint.isEmpty == false ? keyboard.prompt!.hint : "Enter Text",
               isPresented: Binding(get: { keyboard.prompt != nil }, set: { if !$0 && keyboard.prompt != nil { keyboard.cancel() } })) {
            TextField("Text", text: $keyboardText)
            if (keyboard.prompt?.buttonCount ?? 1) >= 2 {
                Button("Cancel", role: .cancel) { keyboard.cancel() }
            }
            Button("OK") { keyboard.submit(keyboardText) }
        }
        .onChange(of: keyboard.prompt?.id) { keyboardText = "" }
        .alert("Can’t Run This Game", isPresented: Binding(get: { if case .failed = core.state { return true }; return false },
                                              set: { if !$0 { closeWindows() } })) {
            Button("OK") { closeWindows() }
        } message: {
            if case .failed(let message) = core.state { Text(message) }
        }
    }

    private func statusCard(_ text: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.headline)
        }
        .padding(28)
        .glassBackgroundEffect()
    }

    private func start() {
        guard !started else { return }
        guard let game = library.games.first(where: { $0.id == request.gameID }), !az_is_running() else {
            VisionDiag.log("game window: nothing to start (\(request.gameID)), closing")
            closeWindows()
            return
        }
        started = true
        let session = VisionGameSession.begin(game)
        self.session = session
        az_set_offscreen_output(true)
        az_set_stereo(true, Int32(depth))
        session.source.attach()
        InputManager.shared.start()
        core.start(game)
        VisionDiag.log("game: \(game.titleIDString) jit=\(JITHelper.isEnabled ? 1 : 0) interpreter \(core.interpreterModeDescription)")
        VisionDiag.log("memory: \(VisionMemoryBudget.availableBytes / 1_048_576) MB available at launch, resolution \(AppSettings.shared.resolutionFactor)× (default \(VisionMemoryBudget.resolutionFactor)×)")
        VisionHangWatchdog.shared.start()
        #if DEBUG
        // -noTouchWindow YES: game window alone (layout and transparency checks).
        let openTouch = !UserDefaults.standard.bool(forKey: "noTouchWindow")
        #else
        let openTouch = true
        #endif
        if openTouch { openWindow(id: VisionWindowID.touch, value: VisionWindowID.touchValue) }
        VisionShellRegistry.current.gameDidStart(openWindow: openWindow, dismissWindow: dismissWindow)
    }

    /// Exit button, Options held, Digital Crown: auto-save, stop; the windows close once the core
    /// is idle (onChange(of: core.state)).
    private func requestExit() {
        guard started, !exiting else { return }
        exiting = true
        core.setPaused(false)
        Task { await VisionGameSession.stopGame(autosave: true) }
    }

    private func closeWindows() {
        guard !closed else { return }
        closed = true
        pendingClose = false
        dismissWindow(id: VisionWindowID.touch, value: VisionWindowID.touchValue)
        dismissWindow()
    }

    /// The window is gone (closed by us or by the player). If the game still runs (window closed
    /// from its own close control), save and stop it before releasing the surface it draws to.
    private func finish() {
        let session = self.session
        self.session = nil
        let launchedHere = started
        Task { @MainActor in
            VisionHangWatchdog.shared.stop()
            if az_is_running() { await VisionGameSession.stopGame(autosave: true) }
            InputManager.shared.stop()
            session?.end()
            az_set_offscreen_output(false)
            az_set_stereo(false, Int32(VisionStereo.defaultDepth))
            GameLibrary.shared.refresh()
            if launchedHere {
                VisionShellRegistry.current.gameDidEnd(openWindow: openWindow)
            }
        }
        dismissWindow(id: VisionWindowID.touch, value: VisionWindowID.touchValue)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                pausedByPhase = false
                core.setPaused(core.state != .paused)
            } label: {
                Label(core.state == .paused ? "Resume" : "Pause",
                      systemImage: core.state == .paused ? "play.fill" : "pause.fill")
            }
            HStack(spacing: 10) {
                Image(systemName: "view.3d")
                // Applying reloads the core settings, so only when the slider is let go (each reload
                // mid-drag was a visible hitch on the device).
                Slider(value: Binding(get: { Double(depth) }, set: { depth = Int($0) }), in: 10...100) { editing in
                    if !editing { applyDepth() }
                }
                .frame(width: 200)
                Text("\(depth)%").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            .help("3D Depth")
            Toggle(isOn: $curved) {
                Label("Curved", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
            }
            .toggleStyle(.button)
            .help("Wrap the top screen around you")
            Text(String(format: "%.0f fps · %.0f%%", core.perf.game_fps, core.perf.emulation_speed * 100))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                openWindow(id: VisionWindowID.touch, value: VisionWindowID.touchValue)
            } label: {
                Label("Bottom Screen", systemImage: "rectangle.bottomhalf.inset.filled")
            }
            .help("Reopen the bottom screen window")
            Button(role: .destructive) {
                requestExit()
            } label: {
                Label("Exit Game", systemImage: "xmark")
            }
            .disabled(exiting)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    private func applyDepth() {
        az_set_stereo(true, Int32(depth))
        core.reloadSettings()
    }
}

/// A game window the system restored without a usable request (saved by an older build): close
/// it and let the shell bring up its own window, so the player never sees an empty one.
struct VisionOrphanWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .onAppear {
                VisionDiag.log("orphan game window closed")
                VisionShellRegistry.current.recoverFromOrphanWindow(openWindow: openWindow)
                dismissWindow()
            }
    }
}

// MARK: - Touch window (bottom screen)

/// The bottom screen in its own window, tilted like a 3DS's lower half. Gaze and pinch on it is
/// touch; pinch-and-drag slides.
struct VisionTouchWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var touching = false

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                guard let session = VisionGameSession.current else { return }
                content.add(session.bottom)
            } update: { content in
                guard let session = VisionGameSession.current else { return }
                let bounds = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                // Keep the tilted panel inside this window. Content that spills over the game window
                // makes visionOS show the game window translucent (seen in the Simulator).
                // The receding top edge also rises in perspective, so leave a 15 % margin.
                session.layoutBottom(width: bounds.extents.x * 0.9, height: bounds.extents.y * 0.85)
            }
            .gesture(touchGesture)
        }
        .background(GameControllerCapture())
        .onAppear {
            // Opened without a game (left over, or reopened by the system): nothing to show.
            if VisionGameSession.current == nil { dismissWindow() }
        }
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToAnyEntity()
            .onChanged { value in
                guard let session = VisionGameSession.current, value.entity === session.bottom,
                      let p = session.touchPoint(value.convert(value.location3D, from: .local, to: value.entity)) else { return }
                if touching {
                    az_touch_move(Float(p.x), Float(p.y))
                } else {
                    touching = az_touch_begin(Float(p.x), Float(p.y))
                }
            }
            .onEnded { _ in
                if touching { az_touch_end() }
                touching = false
            }
    }
}
// MARK: - Controller input

/// On visionOS the system turns game controller input into pinch events for whatever the player
/// looks at, unless the view declares it handles controllers itself (GCEventInteraction). Without
/// this the PS VR2 Sense sticks scrolled the system UI instead of moving Mario.
struct GameControllerCapture: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let interaction = GCEventInteraction()
        interaction.handledEventTypes = .gamepad
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Device diagnostics the Azahar log does not see (controllers, motion, stereo texture), appended
/// to Documents/vision-diag.log so a test run can be read back with devicectl.
enum VisionDiag {
    static func log(_ message: String) {
        NSLog("Holofold %@", message)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vision-diag.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif
