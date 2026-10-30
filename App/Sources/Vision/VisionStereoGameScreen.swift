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
    static let boot = "holofold-boot-6"  // new id (2000x1250): drops the size visionOS saved for the old shelf window
    /// The top screen, in stereo, filling a plain 5:3 window.
    static let game = "holofold-game-4"  // new id: drops any size visionOS kept for the old one
    /// The game's controls: their own window down the game window's left side.
    static let controls = "holofold-controls"
}

/// State the game window and its separate controls window share (the rest goes through the
/// existing AppStorage keys and VisionGameSession.current).
@MainActor
final class VisionControlsModel: ObservableObject {
    static let shared = VisionControlsModel()
    @Published var exiting = false
    /// Paused because the game window became inactive (not by the player).
    @Published var pausedByPhase = false
    @Published var recording = false
    @Published var recordStart = Date()
    @Published var savedClip: URL?
    /// The controls window is on screen (the player can close it; the game window can reopen it).
    @Published var controlsOpen = false
    /// A game window is up: the controls window closes itself otherwise.
    @Published var gameActive = false

    func reset() {
        exiting = false; pausedByPhase = false; recording = false; savedClip = nil
    }
}

/// The shelf window's current size (points), so the game window can open in its exact place and
/// size and the insert animation's screens land where the game's screens appear.
@MainActor enum VisionLaunchGeometry {
    static var shelfSize: CGSize?
    /// Gap between the game window's leading edge and the controls panel / Controls button.
    static let controlsGap: CGFloat = 0

    /// The game window's width for a given height: exactly the screens' width at the default
    /// sizes (layoutScreens' unit), so the window has no empty margin left and right and the
    /// controls window placed `.leading` of it lands right beside the top screen. Never wider
    /// than `size` (then the layout and the insert animation are unchanged: same unit, centered).
    /// Where the controls panel attaches: the top-left corner of the visible screens (not the
    /// window edge), as a UnitPoint of the window. Same math as layoutScreens (window points;
    /// only ratios matter): layout height is 94% of the window, screens centred on the window.
    static func screensTopLeading(window size: CGSize, curved: Bool, topSize: Double, bottomSize: Double,
                                  topTilt: Double = 0) -> UnitPoint {
        let W = Double(size.width), H = Double(size.height)
        guard W > 0, H > 0 else { return .leading }
        let h = H * 0.94
        let tilt = Double(VisionStereo.touchTiltDegrees) * .pi / 180
        let bScale = Double(VisionGameSession.bottomScale)
        let defaultTotal = 0.6 + 0.03 + bScale * 0.75 * cos(tilt)
        var unit = min(W, h / defaultTotal)
        let ts = min(max(topSize, 0.5), 1.5), bs = min(max(bottomSize, 0.5), 1.5)
        let tw = ts, bw = bScale * bs
        let total = tw * 0.6 + 0.03 + bw * 0.75 * cos(tilt)
        unit *= min(1, W / (unit * max(tw, bw)), h / (unit * total))
        // The top screen exactly as layoutScreens/layoutTop place it: width fill * tw (curved
        // margin), centred; its centre line at span/2 - 0.3 tw above the window centre; the tilt
        // (about that line) shortens its projected half-height by cos(pitch).
        let fill = curved ? 0.88 : 1
        let topW = tw * unit * fill
        let r = VisionStereo.screenTiltRange
        let pitch = min(max(topTilt, Double(r.lowerBound)), Double(r.upperBound)) * .pi / 180
        let span = unit * total
        let centreY = span / 2 - tw * unit * 0.3                   // up from the window centre
        let halfH = topW * 0.3 * cos(pitch)
        let left = (W - topW) / 2
        let topEdge = H / 2 - (centreY + halfH)                   // down from the window top
        // The top screen's own top-left corner, so the panel's trailing edge touches the screen.
        return UnitPoint(x: min(max(left / W, 0), 1), y: min(max(topEdge / H, 0), 1))
    }

    /// How far (points) the control bar is pulled toward the player so it is always in front of
    /// the top screen: the original 140 pt, plus the tilted screen's nearest edge. layoutScreens
    /// pushes the screen's centre forward by 0.3 tw |sin p| and the tilt brings an edge a further
    /// 0.3 tw |sin p| forward (tw = the top width in window points here), plus a margin.
    static func controlsDepth(window size: CGSize, curved: Bool, topSize: Double, bottomSize: Double,
                              topTilt: Double) -> CGFloat {
        let W = Double(size.width), H = Double(size.height)
        guard W > 0, H > 0 else { return 140 }
        let h = H * 0.94
        let tilt = Double(VisionStereo.touchTiltDegrees) * .pi / 180
        let bScale = Double(VisionGameSession.bottomScale)
        var unit = min(W, h / (0.6 + 0.03 + bScale * 0.75 * cos(tilt)))
        let ts = min(max(topSize, 0.5), 1.5), bs = min(max(bottomSize, 0.5), 1.5)
        let tw = ts, bw = bScale * bs
        let total = tw * 0.6 + 0.03 + bw * 0.75 * cos(tilt)
        unit *= min(1, W / (unit * max(tw, bw)), h / (unit * total))
        let r = VisionStereo.screenTiltRange
        let pitch = min(max(topTilt, Double(r.lowerBound)), Double(r.upperBound)) * .pi / 180
        let edge = 0.6 * tw * unit * abs(sin(pitch))
        return CGFloat(140 + edge + (pitch == 0 ? 0 : 40))
    }

    static func screensWidth(for size: CGSize) -> CGFloat {
        let tilt = Double(VisionStereo.touchTiltDegrees) * .pi / 180
        let defaultTotal = 0.6 + 0.03 + Double(VisionGameSession.bottomScale) * 0.75 * cos(tilt)
        return min(size.width, (size.height * 0.94 / defaultTotal).rounded(.up))
    }
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
    /// The game's 3D slider: 100 = full stereo depth (the default); 0 = 2D, one eye only (cheaper).
    static let defaultDepth = 100
    /// The live 3D slider in the control bar (0 = 2D at the left, 100 = full depth at the right).
    static let sliderKey = "visionSlider3D"
    /// Live size sliders (fraction of the default size, 0.5...1.5).
    static let topSizeKey = "visionTopScreenSize"
    static let bottomSizeKey = "visionBottomScreenSize"
    /// Bottom screen tilt, top edge away from the player, like a 3DS's lower half.
    static let touchTiltDegrees: Float = 22
    /// Curved top screen (CitraVR's cylinder mode): on/off and the arc's central angle.
    static let curvedKey = "visionCurvedScreen"
    static let curveKey = "visionCurveDegrees"
    static let defaultCurve = 50
    /// Fixed tilt of the top (3D) screen, set on the shelf: degrees about its horizontal axis,
    /// positive = top edge away from the player. 0 = upright (no change).
    static let screenTiltKey = "visionScreenTiltDegrees"
    static let screenTiltRange: ClosedRange<Double> = -30...30
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

    /// Booted from the shelf the moment its cartridge was tapped (load-on-tap), before the game
    /// window exists; the window adopts it instead of starting the core a second time.
    private(set) var prebooted = false
    var adopted = false

    /// Load-on-tap: the same core setup VisionGameWindow.start() does, run while the insert
    /// animation plays. No-op if a game is already running or a session exists. If no window
    /// adopts the session within 20 s (window never opened), the game is stopped again.
    @discardableResult
    static func preboot(_ game: Game) -> Bool {
        guard !az_is_running(), current == nil, EmulatorCore.shared.state == .idle else { return false }
        let session = begin(game)
        let slider = UserDefaults.standard.object(forKey: VisionStereo.sliderKey) as? Double ?? 100
        az_set_offscreen_output(true)
        az_set_stereo(true, Int32(slider))
        session.source.attach()
        session.source.mono = slider < 1
        InputManager.shared.start()
        EmulatorCore.shared.start(game)
        session.prebooted = true
        VisionDiag.log("boot: load-on-tap started \(game.titleIDString) during the insert animation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard current === session, !session.adopted else { return }
            VisionDiag.log("boot: load-on-tap session never adopted by a window, stopping it")
            Task { @MainActor in
                await stopGame(autosave: false)
                InputManager.shared.stop()
                session.end()
                az_set_offscreen_output(false)
                az_set_stereo(false, Int32(VisionStereo.defaultDepth))
            }
        }
        return true
    }

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
        // Hand-off from the dim hold to the game: on the first frame the source delivers once the
        // core reports running (its own fps counter), not on a timer.
        source.onFrameDelivered = { [weak self] in
            guard let self, self.holding, case .running = EmulatorCore.shared.state, self.material != nil,
                  self.sources.top != nil else { return }
            self.releaseHold()
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
        VisionDiag.log("exit: core \(az_is_running() ? "still running 5 s after stop" : "stopped")")
    }

    func end() {
        subscription?.cancel()
        subscription = nil
        materialTask?.cancel()
        source.onSources = nil
        source.onFrameDelivered = nil
        source.detach()
        if Self.current === self { Self.current = nil }
    }

    // MARK: Layout

    /// Top screen (5:3) as large as the window allows: flat, or bent into an arc of `curveDegrees`.
    func layoutTop(width: Float, height: Float, curveDegrees: Float) {
        guard width > 0, height > 0 else { return }
        // A curved screen's edges come toward the player and look larger, so it gets a margin.
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
        top.model = ModelComponent(mesh: mesh, materials: top.model?.materials ?? [Self.holdMaterial])
        topHold.model = ModelComponent(mesh: mesh, materials: [Self.holdMaterial])
        if topHold.parent == nil { top.addChild(topHold); topHold.position = [0, 0, 0.002] }
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

    /// Both 3DS screens in the one game window: the top screen (exactly 400:240) above, the bottom
    /// (4:3, `bottomScale` of the top's width) centered below it, tilted top-away like a 3DS's
    /// lower half. The top screen dominates; touch maps through the bottom panel's own size.
    /// Bottom screen width as a fraction of the top screen's (a real 3DS is 0.8).
    static let bottomScale: Float = 0.40

    /// `topSize` / `bottomSize` are the live size sliders (1 = default, 0.5...1.5). At 1/1 the
    /// layout is the default one, filling the window. The default-sized top width is the unit; the
    /// screens scale from it, and if the result would not fit the window both shrink together.
    /// Layout only: nothing here touches the core, and touch maps through the panel's own size.
    func layoutScreens(width: Float, height: Float, curveDegrees: Float,
                       topSize: Float = 1, bottomSize bottomSlider: Float = 1, topTiltDegrees: Float = 0) {
        guard width > 0, height > 0 else { return }
        let tilt = VisionStereo.touchTiltDegrees * .pi / 180
        let ts = min(max(topSize, 0.5), 1.5), bs = min(max(bottomSlider, 0.5), 1.5)
        // Height in default-top-widths: top 0.6, gap 0.03, bottom (4:3) projected by the tilt.
        let defaultTotal = 0.6 + 0.03 + Self.bottomScale * 0.75 * cos(tilt)
        var unit = min(width, height / defaultTotal)
        var tw = ts, bw = Self.bottomScale * bs
        let total = tw * 0.6 + 0.03 + bw * 0.75 * cos(tilt)
        let widest = max(tw, bw)
        let fit = min(1, width / (unit * widest), height / (unit * total))
        unit *= fit
        tw *= unit; bw *= unit
        layoutTop(width: tw, height: tw * 0.6, curveDegrees: curveDegrees)
        layoutBottom(width: bw, height: bw * 0.75)
        let span = unit * total
        // Fixed tilt about the top screen's horizontal center line. The panel is moved forward by
        // the tilted half-height's depth so neither edge goes behind the window plane (clipped).
        let r = VisionStereo.screenTiltRange
        let pitch = min(max(topTiltDegrees, Float(r.lowerBound)), Float(r.upperBound)) * .pi / 180
        top.orientation = simd_quatf(angle: -pitch, axis: [1, 0, 0])
        top.position = [0, span / 2 - tw * 0.3, tw * 0.3 * abs(sin(pitch))]
        bottom.position = [0, -span / 2 + bw * 0.75 / 2 * cos(tilt), 0]
    }

    /// Bottom screen (4:3) as large as the given area allows, tilted top-away.
    func layoutBottom(width: Float, height: Float) {
        guard width > 0, height > 0 else { return }
        let w = min(width, height * 4 / 3), h = w * 0.75
        guard (w, h) != bottomSize else { return }
        bottomSize = (w, h)
        bottom.model = ModelComponent(mesh: .generatePlane(width: w, height: h),
                                      materials: bottom.model?.materials ?? [Self.holdMaterial])
        bottomHold.model = ModelComponent(mesh: .generatePlane(width: w, height: h), materials: [Self.holdMaterial])
        if bottomHold.parent == nil { bottom.addChild(bottomHold); bottomHold.position = [0, 0, 0.002] }
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

    /// The lit-screen color the insert animation ends on. Both screens hold it until the game has
    /// drawn real frames, so the hand-off shows no black gap.
    /// A dim neutral glow (not white): the same value the insert animation's lit screens use.
    static let holdColor = UIColor(white: 0.14, alpha: 1)
    static let holdMaterial = UnlitMaterial(color: holdColor)
    private(set) var holding = true
    /// Copies of the two screens drawn just in front in the hold color. While holding they cover
    /// the game material; on the first real frame they fade out (0.3 s), a cross-fade to the game.
    let topHold = ModelEntity()
    let bottomHold = ModelEntity()
    static let holdFade: Double = 0.30

    func releaseHold() {
        guard holding else { return }
        holding = false
        VisionDiag.log("game window: first real frame delivered, cross-fading the held screens")
        applyAll()
        for e in [topHold, bottomHold] {
            e.components.set(OpacityComponent(opacity: 1))
            let fade = FromToByAnimation<Float>(from: 1, to: 0, duration: Self.holdFade, timing: .easeInOut, bindTarget: .opacity)
            if let res = try? AnimationResource.generate(with: fade) { e.playAnimation(res) } else { e.isEnabled = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdFade + 0.05) { [weak self] in
            self?.topHold.isEnabled = false
            self?.bottomHold.isEnabled = false
        }
    }

    /// The game material goes on as soon as it and the texture exist (under the hold overlays).
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
/// closes both windows, and the launcher comes back. Pause / 3D depth / exit sit in an ornament
/// that stays hidden (it took gaze focus and controller input from the game) until the touchpad is
/// clicked (or Start + Select pressed) on a controller; it hides itself again after a few seconds.
///
/// Leaving can start in the background (Digital Crown → Home View), where dismissing windows is
/// unreliable, so the windows only close once the app is active again (`pendingClose`).
struct VisionGameWindow: View {
    let request: VisionGameRequest
    @AppStorage(VisionStereo.sliderKey) private var slider3D = 100.0
    @AppStorage(VisionStereo.topSizeKey) private var topSize = 1.0
    @AppStorage(VisionStereo.bottomSizeKey) private var bottomSize = 1.0

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var core = EmulatorCore.shared
    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var keyboard = VisionKeyboard.shared
    @State private var keyboardText = ""
    @AppStorage(VisionStereo.curvedKey) private var curved = true
    @AppStorage(VisionStereo.curveKey) private var curve = VisionStereo.defaultCurve
    @AppStorage(VisionStereo.screenTiltKey) private var screenTilt = 0.0
    @State private var session: VisionGameSession?
    @State private var started = false
    @State private var pendingClose = false
    @State private var hidden = false
    @Environment(\.dismiss) private var dismiss
    @State private var closed = false
    @State private var resumed = false
    /// Paused because the window became inactive (not by the player); resumed when it is active.
    @ObservedObject private var ctl = VisionControlsModel.shared
    @State private var controlsOpened = false
    /// The window's real size in points (logged), for the controls panel's content-relative anchor.
    @State private var windowSize = CGSize.zero
    @State private var touching = false

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                guard let session else { return }
                content.add(session.top)
                content.add(session.bottom)
                session.startPumping(in: content)
            } update: { content in
                guard let session else { return }
                let bounds = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                // Both screens in this one window; a small margin for the tilted bottom screen's edge.
                session.layoutScreens(width: bounds.extents.x, height: bounds.extents.y * 0.94,
                                      curveDegrees: curved ? Float(curve) : 0,
                                      topSize: Float(topSize), bottomSize: Float(bottomSize),
                                      topTiltDegrees: Float(screenTilt))
            }
            .gesture(touchGesture)
            .onChange(of: proxy.size, initial: true) { _, s in
                windowSize = CGSize(width: s.width, height: s.height)
                VisionDiag.log("game window size \(Int(s.width))×\(Int(s.height)) pt")
            }
            .id(session.map { ObjectIdentifier($0) })
            .background { TopShellView() }
            .background(Color.clear)
            .glassBackgroundEffect(displayMode: .never)   // no backing behind the screens
            .overlay {
                if hidden {
                    Color.clear
                } else if ctl.exiting {
                    statusCard("Saving and exiting…")
                } else if case .loading(let stage, _) = core.state, session?.holding != true {
                    statusCard(stage < 4 ? "Loading game…" : "Starting…")
                }
            }
        }
        // The control bar, as originally: one glass row centred on the top screen's top edge
        // (same geometry as layoutScreens: curve margin, sizes, tilt, window size), always shown,
        // pulled toward the player so the curved screen's corners never hide it.
        .ornament(visibility: started ? .visible : .hidden,
                  attachmentAnchor: .scene(UnitPoint(x: 0.5, y: VisionLaunchGeometry.screensTopLeading(
                      window: windowSize, curved: curved, topSize: topSize, bottomSize: bottomSize,
                      topTilt: screenTilt).y)),
                  contentAlignment: .bottom) {
            VisionControlsWindow()
                .padding(.bottom, 32)   // a little gap above the top screen's top edge
                // Real 3D depth, not z-order: in front of the tilted top screen's nearest edge too.
                .offset(z: VisionLaunchGeometry.controlsDepth(window: windowSize, curved: curved,
                                                             topSize: topSize, bottomSize: bottomSize,
                                                             topTilt: screenTilt))
        }
        // The controller belongs to the game: visionOS then sends no gamepad events to this
        // window's UI (no focus, no Cross presses on the bar), and GameController gets them all.
        .handlesGameControllerEvents(matching: .gamepad)
        .opacity(hidden ? 0 : 1)
        .onAppear { VisionWindowTracker.gameWindowGone = false; start() }
        .onDisappear { VisionWindowTracker.gameWindowGone = true; finish() }
        .onChange(of: scenePhase) { _, phase in
            VisionDiag.log("game window scene: \(phase)")
            switch phase {
            case .background:
                // Digital Crown → Home View, or the headset went to sleep.
                VisionDiag.log("exit: scene went to background")
                requestExit()
            case .inactive:
                // Keep running. Looking at or pinching the bottom-screen window (or a system
                // overlay) makes this window inactive; pausing then froze the game while the
                // controller kept playing into nothing. Background still exits via requestExit().
                break
            case .active:
                if pendingClose { closeWindows() }
                if started && !closed { openControls() }
                if ctl.pausedByPhase {
                    ctl.pausedByPhase = false
                    if core.state == .paused { core.setPaused(false) }
                }
            @unknown default:
                break
            }
        }
        // Options held on a controller (the PS button itself is the system's).
        .onReceive(NotificationCenter.default.publisher(for: .bifoldExitGame)) { _ in requestExit() }
        .onReceive(NotificationCenter.default.publisher(for: .bifoldToggleControls)) { _ in
            // Touchpad click / Start + Select: bring the controls window back if it was closed.
            if !ctl.controlsOpen { ctl.controlsOpen = true }
            VisionDiag.log("controls panel: reopen requested (open \(ctl.controlsOpen))")
        }
        .onChange(of: core.state) { _, state in
            // The hold is released by the session on the first delivered frame (onFrameDelivered).
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
        let pre = VisionGameSession.current.flatMap {
            $0.game.id == request.gameID && $0.prebooted && !$0.adopted ? $0 : nil
        }
        guard let game = library.games.first(where: { $0.id == request.gameID }), pre != nil || !az_is_running() else {
            VisionDiag.log("game window: nothing to start (\(request.gameID)), closing")
            closeWindows()
            return
        }
        started = true
        if let pre {
            // Load-on-tap: the core was started from the shelf; adopt it, never start it twice.
            pre.adopted = true
            self.session = pre
            VisionDiag.log("game window: adopting the load-on-tap session (state \(core.state))")
        } else {
            let session = VisionGameSession.begin(game)
            self.session = session
            az_set_offscreen_output(true)
            az_set_stereo(true, Int32(slider3D))   // always stereo; the live slider sets the depth
            session.source.attach()
            InputManager.shared.start()
            core.start(game)
        }
        guard let session = self.session else { return }
        VisionDiag.log("game: \(game.titleIDString) jit=\(JITHelper.isEnabled ? 1 : 0) interpreter \(core.interpreterModeDescription)")
        VisionDiag.log("memory: \(VisionMemoryBudget.availableBytes / 1_048_576) MB available at launch, resolution \(AppSettings.shared.resolutionFactor)× (default \(VisionMemoryBudget.resolutionFactor)×)")
        let s = AppSettings.shared
        VisionDiag.log("stability: resolution \(s.resolutionFactor)×, asyncShaders \(s.asyncShaders), accurateMul \(s.accurateMul), gpuTimings \(s.gpuTimings), frameLimit \(s.frameLimit), fxaa \(StereoFrameSource.fxaaEnabled), slider \(Int(slider3D)), vkPipelineFastPath \(s.vkPipelineFastPath), vkSkipUnreadyDraws \(s.vkSkipUnreadyDraws), vkAsyncQueueSubmits \(s.vkAsyncQueueSubmits), gspResignal \(s.gspResignalStalled), jit \(JITHelper.isEnabled)")
        VisionHangWatchdog.shared.start()
        session.source.mono = slider3D < 1
        VisionShellRegistry.current.gameDidStart(openWindow: openWindow, dismissWindow: dismissWindow)
        ctl.reset()
        ctl.gameActive = true
        // The controls window opens once this window is active (so placement finds it in
        // context.windows); a fallback opens it after 1 s if no phase change arrives.
        if scenePhase == .active { openControls() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openControls() }
    }

    /// Exit button, Options held, Digital Crown: auto-save, stop; the windows close once the core
    /// is idle (onChange(of: core.state)).
    private func requestExit() {
        guard started, !ctl.exiting else { return }
        ctl.exiting = true
        VisionDiag.log("exit: requested (state \(core.state), running \(az_is_running()))")
        // The hang watchdog must not read the exit stop as a freeze and run recovery steps
        // (settings reload, audio / GPU re-init) into a core that is tearing down.
        VisionHangWatchdog.shared.stop()
        core.setPaused(false)
        Task { await VisionGameSession.stopGame(autosave: false) }
        // Watchdog: a hung guest or a core that never reports idle must not keep the player in
        // the game. After ~2 s return to the library anyway; finish() keeps stopping the core.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !closed else { return }
            VisionDiag.log("exit: core still \(core.state) after 2 s (running \(az_is_running())), closing windows anyway")
            closeWindows()   // whatever the scene phase: the close below retries and falls back
        }
    }

    /// Opens the controls window once per game (the player can reopen it from the Controls button).
    private func openControls() {
        guard started, !closed, !controlsOpened, !ctl.exiting else { return }
        controlsOpened = true
        VisionDiag.log("controls panel: shown beside the screens")
        ctl.controlsOpen = true
    }

    private func closeWindows() {
        guard !closed else { return }
        closed = true
        pendingClose = false
        ctl.gameActive = false
        ctl.controlsOpen = false
        VisionDiag.log("exit: closing the game window, library back")
        // Bring the library back before dismissing: visionOS ignores dismissing an app's last open
        // window, which left the game window stuck on "Saving and exiting…" (when the bottom-screen
        // window was closed first, the game window is the only one).
        // The bug (vision-diag.log, Oct 28): openWindow(boot) is asynchronous, so the dismiss right
        // after it still saw the game window as the app's last window and visionOS ignored it; the
        // game window stayed on "Saving and exiting…" with no "disappeared" until a force quit.
        // Now: note this window's scenes, open the library, wait until it is really on screen,
        // dismiss by the current id and value, and if the window is still there destroy its scene.
        let mine = UIApplication.shared.connectedScenes.filter { $0.activationState != .unattached }
            .map(\.session)
        if started { VisionShellRegistry.current.gameDidEnd(openWindow: openWindow) }
        let request = self.request
        let dismissWindow = self.dismissWindow
        let dismiss = self.dismiss
        let session = self.session
        Task { @MainActor in
            for _ in 0..<30 where !VisionWindowTracker.open.contains("boot") {
                try? await Task.sleep(for: .milliseconds(100))
            }
            VisionDiag.log("exit: dismissing \(VisionWindowID.game) (library open: \(VisionWindowTracker.open.contains("boot")))")
            dismissWindow(id: VisionWindowID.game, value: request)
            try? await Task.sleep(for: .milliseconds(600))
            guard !VisionWindowTracker.gameWindowGone else { return }
            VisionDiag.log("exit: game window still open, retrying dismiss")
            dismiss()
            dismissWindow(id: VisionWindowID.game)
            try? await Task.sleep(for: .milliseconds(900))
            guard !VisionWindowTracker.gameWindowGone else { return }
            // Last resort: blank the window and ask UIKit to destroy its scene session(s).
            session?.top.isEnabled = false
            session?.bottom.isEnabled = false
            hidden = true
            let open = VisionWindowTracker.open
            let bootSessions = Set(UIApplication.shared.connectedScenes.map(\.session)).subtracting(mine)
            VisionDiag.log("exit: still open after dismiss, destroying \(mine.count) scene session(s) (library sessions \(bootSessions.count), open \(open))")
            for s in mine where !bootSessions.contains(s) {
                UIApplication.shared.requestSceneSessionDestruction(s, options: nil) { e in
                    VisionDiag.log("exit: scene destruction failed: \(e)")
                }
            }
        }
    }

    /// The window is gone (closed by us or by the player). If the game still runs (window closed
    /// from its own close control), save and stop it before releasing the surface it draws to.
    private func finish() {
        let session = self.session
        self.session = nil
        let launchedHere = started
        if ctl.recording { ctl.recording = false; VisionRecorder.shared?.stop { _ in } }
        ctl.gameActive = false
        ctl.controlsOpen = false
        Task { @MainActor in
            VisionHangWatchdog.shared.stop()
            if az_is_running() { await VisionGameSession.stopGame(autosave: false) }
            InputManager.shared.stop()
            session?.end()
            az_set_offscreen_output(false)
            az_set_stereo(false, Int32(VisionStereo.defaultDepth))
            GameLibrary.shared.refresh()
            if launchedHere {
                VisionShellRegistry.current.gameDidEnd(openWindow: openWindow)
            }
        }
    }

    /// Gaze and pinch on the bottom screen is 3DS touch; pinch-and-drag slides.
    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToAnyEntity()
            .onChanged { value in
                guard let session, value.entity === session.bottom,
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

// MARK: shell-begin

struct TopShellView: View {
    /// Share of the window the screen fills (no border: edge to edge).
    static let screenShare: Float = 1
    var body: some View { Color.clear }
}

struct BottomShellView: View {
    static let screenShare: Float = 0.9
    var body: some View { Color.clear }
}

// MARK: shell-end

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

/// Which windows are on screen (by VisionPhaseLogger name), and whether the game window is gone.
@MainActor enum VisionWindowTracker {
    static var open: Set<String> = []
    static var gameWindowGone = true
}

/// Logs a window's scene phase so focus hand-offs show in vision-diag.log.
struct VisionPhaseLogger: ViewModifier {
    let name: String
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content
            .onAppear { VisionWindowTracker.open.insert(name); VisionDiag.log("\(name) window appeared") }
            .onDisappear { VisionWindowTracker.open.remove(name); VisionDiag.log("\(name) window disappeared") }
            .onChange(of: phase) { _, p in VisionDiag.log("\(name) window scene: \(p)") }
    }
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
// MARK: - Controls window

/// The game's controls in their own window down the game window's left side (the player can drag
/// panel attached as an ornament (closable, reopened by its Controls button): the three sliders as horizontal rows, then the buttons stacked below. Shares
/// state with the game window through the AppStorage keys, VisionControlsModel and
/// VisionGameSession.current; Exit goes through the game window's own save-and-exit flow.
struct VisionControlsWindow: View {
    @AppStorage(VisionStereo.sliderKey) private var slider3D = 100.0
    @AppStorage(VisionStereo.topSizeKey) private var topSize = 1.0
    @AppStorage(VisionStereo.bottomSizeKey) private var bottomSize = 1.0
    @AppStorage(VisionStereo.curvedKey) private var curved = true
    @AppStorage(VisionStereo.screenTiltKey) private var screenTilt = 0.0
    @AppStorage(VisionRecorder.includeTouchKey) private var recordTouch = true
    @ObservedObject private var core = EmulatorCore.shared
    @ObservedObject private var ctl = VisionControlsModel.shared
    @Environment(\.dismissWindow) private var dismissWindow

    /// Which size/tilt slider is popped open inline in the bar (one at a time).
    @State private var adjusting: String?

    var body: some View {
        HStack(spacing: 14) {
            Button {
                ctl.pausedByPhase = false
                core.setPaused(core.state != .paused)
            } label: {
                Label(core.state == .paused ? "Resume" : "Pause",
                      systemImage: core.state == .paused ? "play.fill" : "pause.fill")
            }
            .focusable(false).focusEffectDisabled()  // a controller Cross must never press it
            // Like the 3DS's slider: 2D at the left, full 3D at the right. Live, no settings reload.
            HStack(spacing: 8) {
                Image(systemName: "view.3d")
                Slider(value: $slider3D, in: 0...100)
                    .frame(width: 150)
                    .focusable(false).focusEffectDisabled()
                Text(slider3D < 1 ? "2D" : "\(Int(slider3D.rounded()))%")
                    .monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            .onChange(of: slider3D) { _, v in
                az_set_3d_slider(Int32(v.rounded()))
                VisionGameSession.current?.source.mono = v < 1
            }
            .help("3D Depth")
            // Top / Bottom size and Tilt: small buttons, each pops its slider inline (layout only).
            ForEach(["Top", "Bottom", "Tilt"], id: \.self) { name in
                Button(name) { adjusting = adjusting == name ? nil : name }
                    .buttonStyle(.bordered)
                    .tint(adjusting == name ? .accentColor : nil)
                    .focusable(false).focusEffectDisabled()
            }
            if let name = adjusting {
                HStack(spacing: 8) {
                    switch name {
                    case "Top":
                        Slider(value: $topSize, in: 0.5...1.5).frame(width: 150)
                        Text("\(Int((topSize * 100).rounded()))%").monospacedDigit().frame(width: 52)
                    case "Bottom":
                        Slider(value: $bottomSize, in: 0.5...1.5).frame(width: 150)
                        Text("\(Int((bottomSize * 100).rounded()))%").monospacedDigit().frame(width: 52)
                    default:
                        Slider(value: $screenTilt, in: VisionStereo.screenTiltRange, step: 1).frame(width: 150)
                        Text("\(Int(screenTilt.rounded()))°").monospacedDigit().frame(width: 44)
                    }
                    Button {
                        switch name {
                        case "Top": topSize = 1
                        case "Bottom": bottomSize = 1
                        default: screenTilt = 0
                        }
                    } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Reset \(name)")
                    .focusable(false).focusEffectDisabled()
                }
                .focusable(false).focusEffectDisabled()
                .transition(.opacity)
            }
            // Live Curved / Flat: the layout swaps the top screen's mesh, no reload.
            Toggle(isOn: $curved) {
                Label("Curved", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
            }
            .toggleStyle(.button)
            .focusable(false).focusEffectDisabled()
            Text(String(format: "%.0f fps · %.0f%%", core.perf.game_fps, core.perf.emulation_speed * 100))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            Button(role: .destructive) {
                NotificationCenter.default.post(name: .bifoldExitGame, object: nil)   // the game window's requestExit()
            } label: {
                Label("Exit", systemImage: "xmark")
            }
            .focusable(false).focusEffectDisabled()
            .disabled(ctl.exiting)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: adjusting)
        // The controller stays with the game: no focus or Cross presses on these controls.
        .handlesGameControllerEvents(matching: .gamepad)
    }

    /// One slider style for all three: a plain horizontal Slider (no rotation transform, so the
    /// knob is drawn at the bound value), the name above it (the value is spoken by VoiceOver, not shown).
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           valueText: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.body.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A fixed track width: inside an ornament the row first lays out with no width
            // proposal, and the knob was positioned for that collapsed track (left / mid-track).
            Slider(value: value, in: range)
                .tint(Color(white: 0.30))
                .frame(width: 260)
                .focusable(false).focusEffectDisabled()
                .accessibilityValue(valueText)
        }
        .frame(width: 260)
    }

    private func sizeSlider(_ title: String, value: Binding<Double>) -> some View {
        sliderRow(title, value: value, in: 0.5...1.5, valueText: "\(Int((value.wrappedValue * 100).rounded()))%")
            .simultaneousGesture(TapGesture(count: 2).onEnded { value.wrappedValue = 1 })
    }

    /// Demo recorder: the emulator's own stereo output to an MP4 (full side-by-side, left | right eye).
    /// Passthrough can't be included: visionOS gives apps no camera frames without the Enterprise
    /// main-camera-access entitlement. Control Center's Record My View captures passthrough instead.
    var recordControl: some View {
        VStack(spacing: 12) {
            Button {
                if ctl.recording {
                    ctl.recording = false
                    VisionRecorder.shared?.stop { url in ctl.savedClip = url }
                } else {
                    ctl.savedClip = nil
                    ctl.recording = VisionRecorder.shared?.start() ?? false
                    ctl.recordStart = Date()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 12, height: 12)
                        .opacity(ctl.recording ? 1 : 0.55)
                    if ctl.recording {
                        TimelineView(.periodic(from: ctl.recordStart, by: 1)) { ctx in
                            let t = Int(ctx.date.timeIntervalSince(ctl.recordStart))
                            Text(String(format: "REC %d:%02d", t / 60, t % 60)).font(.body.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("Record").font(.body.weight(.semibold))
                    }
                }
                .barButtonLabel()
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .focusable(false).focusEffectDisabled()
            Toggle("Rec Touch", isOn: $recordTouch)   // whether the clip includes the touch screen
                .toggleStyle(.button).font(.body.weight(.semibold))
                .lineLimit(1).frame(minWidth: 130, minHeight: 44).fixedSize()
                .disabled(ctl.recording)
                .focusable(false).focusEffectDisabled()
            if let savedClip = ctl.savedClip, !ctl.recording {
                ShareLink(item: savedClip) { Label("Share clip", systemImage: "square.and.arrow.up").barButtonLabel() }
                    .buttonStyle(.bordered).fixedSize()
                    .focusable(false).focusEffectDisabled()
            }
        }
    }

}

/// Game bar buttons: one line, readable, never narrower than a real button.
private extension View {
    func barButtonLabel() -> some View {
        self.font(.body.weight(.semibold)).lineLimit(1)
            .frame(minWidth: 120, minHeight: 44)
    }
}
#endif
