#if os(visionOS) && !HOLOFOLD_FULL_SHELL
import AzaharCore
import AudioToolbox
import GameController
import SwiftUI
#if os(visionOS)
import RealityKit
#endif

/// Holofold's public entry point. The library window installs any .cia dropped into the app's
/// folder and shows the games on shelves; picking one opens the game windows and closes it. Leaving the game
/// (hold Options, Exit Game, Digital Crown) stops it without a save state;
/// every launch is a cold boot.
@main
struct HolofoldApp: App {
    init() {
        VisionShellRegistry.current = MinimalShell()
        VisionAppSetup.run()
    }

    var body: some SwiftUI.Scene {
        // A single-instance Window: a second boot window could never be dismissed with the game's.
        Window("Holofold", id: VisionWindowID.boot) {
            BootView()
                .background(GameControllerCapture())
                .modifier(VisionPhaseLogger(name: "boot"))
                .onOpenURL { url in
                    if url.isFileURL { GameLibrary.shared.importFiles([url]) }
                }
        }
        .windowStyle(.plain)
        .defaultSize(width: 2000, height: 1250)   // room for the insert animation (it scales to the window); drag bigger
        .windowResizability(.contentMinSize)   // freely expandable past the content's size
        .restorationBehavior(.disabled)

        VisionGameScenes()
    }
}

/// Which game to boot. Configured with HOLOFOLD_AUTOBOOT_TITLE_ID / HOLOFOLD_AUTO_RESUME
/// (App/Config/Holofold.xcconfig, overridden in Local.xcconfig), or the -autoboot launch argument.
enum BootChoice {
    /// The bundled open-source homebrew used when no game of your own is installed. It uses the
    /// stereoscopic top screen, so a fresh build shows something meaningful.
    static let fallbackFile = "StarCruiser7.3dsx"

    static var configured: String? {
        let fromArgument = UserDefaults.standard.string(forKey: "autoboot")
        let fromBuild = Bundle.main.object(forInfoDictionaryKey: "HolofoldAutoBootTitleID") as? String
        for value in [fromArgument, fromBuild] {
            if let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty, !v.hasPrefix("$(") { return v }
        }
        return nil
    }

    static func pick(from games: [Game]) -> Game? {
        if let wanted = configured {
            if let g = games.first(where: { $0.titleIDString == wanted.uppercased() || $0.url.lastPathComponent == wanted }) {
                return g
            }
            VisionDiag.log("boot: configured game \(wanted) not found")
        }
        let own = games.filter { !$0.isBundled }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if let first = own.first { return first }
        return games.first { $0.url.lastPathComponent == fallbackFile } ?? games.first
    }
}

/// The boot window: scans the library (installing any dropped .cia), then shows the games as covers
/// standing on shelves (the FlycastVision launcher's look). Look-and-tap, or the controller:
/// d-pad / left stick to move, A (or ✕) to play. A configured auto-boot game skips the shelf.
private struct BootView: View {
    @ObservedObject private var library = GameLibrary.shared
    @StateObject private var nav = LibraryNavigator()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var status: LocalizedStringKey = "Starting…"
    @State private var ready = false
    @State private var booted = false
    @State private var launching = false
    @State private var inserting: Game?
    @State private var insertPhase = 0
    @State private var insertToken: UUID?
    @State private var coverFrames: [Game.ID: CGRect] = [:]
    @State private var showImporter = false

    /// Carts per row: reflows with the window width (fixed-size carts, more fit as it grows).
    @State private var columns = 4
    /// Cart width, scaled from the window width so the shelves fill it (4 per row).
    private let cover: CGFloat = 220

    private var games: [Game] {
        library.games.sorted {
            if $0.isBundled != $1.isBundled { return !$0.isBundled }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if !ready {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status).font(.headline)
                }
                .padding(28)
            } else if games.isEmpty {
                VStack(spacing: 20) {
                    Text("No games yet. Import a decrypted .3ds, .cci, .cxi, .cia or .3dsx you dumped yourself, or copy it into Files › Holofold.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    importButton
                }
                .padding(40)
            } else {
                shelves
            }
        }
        .frame(minWidth: 520, minHeight: 180)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { VisionLaunchGeometry.shelfSize = $0 }
        // Tapping a cartridge clears the whole shelf (glass included) so the console flies alone.
        .glassBackgroundEffect(displayMode: inserting != nil ? .never : .always)
        // Copies the picked files into Documents/Games (security-scoped), like LibraryView.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: GameLibrary.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .onDisappear { inserting = nil; insertPhase = 0; insertToken = nil }
        .task { await boot() }
        .onAppear { nav.attach(count: { games.count }, columns: columns) { insert(games[$0]) } }
        .onDisappear { nav.detach() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            nav.attach(count: { games.count }, columns: columns) { insert(games[$0]) }
        }
    }

    /// The session's display mode, picked here before a game starts and fixed until it exits
    /// (no live 3D / curve switching in the game window, like the other launchers).
    @AppStorage(VisionStereo.curvedKey) private var curved = true

    private var modePicker: some View {
        HStack(spacing: 16) {
            importButton
            texturesButton
            Picker("Screen", selection: $curved) {
                Text("Flat").tag(false)
                Text("Curved").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .focusable(false).focusEffectDisabled()  // the controller moves the cartridge selection only
        .disabled(inserting != nil)
    }

    /// Opens the file picker; the picked games are copied into the library.
    private var importButton: some View {
        Button { showImporter = true } label: {
            Label("Import Games", systemImage: "square.and.arrow.down")
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .hoverEffect(.highlight)
        .disabled(inserting != nil || library.installingName != nil)
    }

    @AppStorage("customTextures") private var customTextures = true
    @AppStorage("preloadTextures") private var preloadTextures = false
    /// Azahar texture_sampling: 0 = game-controlled (default), 2 = Linear.
    @AppStorage("textureSampling") private var textureSampling = 0

    @State private var showTextures = false

    /// Texture packs: read when a game boots, so they are set here on the shelf. A popover with a
    /// fixed width (a Menu with a long caption grew past the window edge and opened under the
    /// Flat/Curved picker, hiding "Preload textures").
    private var texturesButton: some View {
        Button { showTextures.toggle() } label: {
            Label("Textures", systemImage: customTextures ? "photo.fill.on.rectangle.fill" : "photo.on.rectangle")
        }
        .popover(isPresented: $showTextures, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Use custom textures", isOn: $customTextures)
                Toggle("Preload textures", isOn: $preloadTextures).disabled(!customTextures)
                Toggle("Linear texture sampling", isOn: Binding(
                    get: { textureSampling == 2 }, set: { textureSampling = $0 ? 2 : 0 }))
                Text("Takes effect on the next game boot.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Folder: Azahar › load › textures › <title ID>")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(width: 380)
        }
    }

    private var shelves: some View {
        let rows = stride(from: 0, to: games.count, by: columns).map { Array(games[$0..<min($0 + columns, games.count)].enumerated()).map { ($0.offset, $0.element) } }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 24) {
                        Text("Holofold").font(.largeTitle.bold())
                        Spacer()
                        modePicker
                    }
                    .padding(.horizontal, 56)
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        ZStack(alignment: .bottom) {
                            Shelf().frame(height: 22).padding(.horizontal, 24).offset(y: -10).depthZ(0)
                            HStack(alignment: .top, spacing: 36) {
                                ForEach(row, id: \.1.id) { c, game in
                                    let index = r * columns + c
                                    CoverButton(game: game, size: cover, selected: nav.selected == index) { insert(game) }
                                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { coverFrames[game.id] = $0 }
                                        .opacity(inserting?.id == game.id ? 0 : 1)
                                        .id(index)
                                }
                            }
                            .padding(.horizontal, 56)
                        }
                    }
                }
                .padding(.vertical, 32)
            }
            .opacity(inserting == nil ? 1 : 0)
            .allowsHitTesting(inserting == nil)
            .onChange(of: nav.selected) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
        }
        .frame(minWidth: 1000, idealWidth: 2000, maxWidth: 5000, minHeight: 700, idealHeight: 1250, maxHeight: 3000)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            let n = max(1, Int((w - 112 + 36) / (cover + 36)))
            if n != columns { columns = n; nav.setColumns(n) }
        }
        .coordinateSpace(name: Self.space)
        .overlay {
            if let game = inserting {
                InsertAnimationView(icon: game.icon.map { Image(uiImage: $0) }, title: game.title, subtitle: game.publisher,
                                    art: CoverArtStore.shared.cover(for: game).map { Image(uiImage: $0) },
                                    width: cover * 1.1, phase: insertPhase,
                                    start: coverFrames[game.id].map { CGRect(x: $0.minX, y: $0.maxY - $0.width * 0.9 * CartridgeView.aspect - 30, width: $0.width * 0.9, height: $0.width * 0.9 * CartridgeView.aspect) })
                    .onTapGesture { finishInsert() }
            }
        }
    }

    /// Takes the cartridge off the shelf, slides it into the slot, turns the console around, opens it,
    /// lights the screens and zooms into them (≈3 s), then boots.
    /// Selecting again (A or a tap) skips to the boot.
    static let space = "library"

    private func insert(_ game: Game) {
        if inserting != nil { finishInsert(); return }   // second tap: skip to the boot (no second load)
        guard !launching, !az_is_running() else { return }
        insertPhase = 0
        // Load-on-tap: the core and ROM start loading now, in parallel with the fly-out; the game
        // window adopts this session when it opens (VisionGameWindow.start).
        VisionGameSession.preboot(game)
        // The shelf and its glass fade out first (0.3 s); the cart then flies on its own.
        withAnimation(.easeOut(duration: 0.30)) { inserting = game }
        let token = UUID()
        insertToken = token
        // About 5 s, one continuous eased move per beat: pop the cart in (cover to you), set the
        // console around (upright), open it, zoom into the screens. A or a tap skips.
        func at(_ t: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30 + t) { guard insertToken == token else { return }; body() }
        }
        at(0) { withAnimation(.easeOut(duration: 0.24)) { insertPhase = 1 } }                         // lift out of the shelf
        at(0.24) { withAnimation(.smooth(duration: 0.40)) { insertPhase = 2 } }                       // glide toward you
        at(0.64) { withAnimation(.easeInOut(duration: 0.32)) { insertPhase = 3 } }                    // console rises behind it, slot up
        at(0.96) { withAnimation(.easeInOut(duration: 0.28)) { insertPhase = 4 } }                    // cart lines up over the slot
        at(1.24) { withAnimation(.easeIn(duration: 0.32)) { insertPhase = 5 } }                       // slides in
        at(1.56) { withAnimation(.easeOut(duration: 0.08)) { insertPhase = 6 } }                      // last push past flush
        at(1.62) { AudioServicesPlaySystemSound(1104) }                                               // click
        at(1.64) { withAnimation(.spring(duration: 0.24, bounce: 0.25)) { insertPhase = 7 } }         // springs back flush
        at(1.92) { withAnimation(.easeInOut(duration: 0.68)) { insertPhase = 8 } }                    // spins around to face you, upright
        at(2.60) { withAnimation(.spring(duration: 0.52, bounce: 0.12)) { insertPhase = 9 } }         // lid hinges open
        at(3.00) { withAnimation(.easeOut(duration: 0.24)) { insertPhase = 10 } }                     // screens light
        at(3.24) { withAnimation(.easeInOut(duration: 0.64)) { insertPhase = 11 } }                   // zoom into the screens
        at(4.00) { finishInsert() }
    }

    private func finishInsert() {
        guard let game = inserting else { return }
        insertToken = nil
        // Jump to the end pose (screens laid out where the game's will be) if skipped early.
        if insertPhase < 11 { insertPhase = 11 }
        play(game)
        // The shelf stays cleared (no glass flash) until the game window replaces it; onDisappear resets.
    }

    private func play(_ game: Game) {
        let prebooted = VisionGameSession.current.map { $0.game.id == game.id && $0.prebooted && !$0.adopted } ?? false
        guard !launching, prebooted || !az_is_running() else { return }
        launching = true
        nav.detach()
        VisionDiag.log("boot: \(game.titleIDString) \(game.url.lastPathComponent) cold (from library)")
        openWindow(id: VisionWindowID.game, value: VisionGameRequest(gameID: game.id, resume: false))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { launching = false }
    }

    private func boot() async {
        guard !booted else { return }
        booted = true
        if az_is_running() {
            // A game is already up (this window came back through the shell): nothing to do.
            dismissWindow()
            return
        }
        library.refresh()
        // Wait for the scan, including .cia installs (several hundred MB take a while).
        for _ in 0..<1200 {
            try? await Task.sleep(for: .milliseconds(250))
            if let name = library.installingName {
                status = "Installing \(name)…"
            } else if !library.isScanning {
                break
            }
        }
        ready = true
        VisionDiag.log("library: \(games.count) game(s)")
        // A build- or argument-configured game boots straight away (development); otherwise the shelf.
        if BootChoice.configured != nil, let game = BootChoice.pick(from: library.games) {
            play(game)
        }
    }
}

/// One game as a cartridge on the shelf: its SMDH icon and title on the label.
private struct CoverButton: View {
    let game: Game
    let size: CGFloat
    let selected: Bool
    let action: () -> Void
    @ObservedObject private var covers = CoverArtStore.shared

    var body: some View {
        Button(action: action) {
            CartridgeView(icon: game.icon.map { Image(uiImage: $0) }, title: game.title,
                          subtitle: game.publisher, width: size * 0.9,
                          art: covers.cover(for: game).map { Image(uiImage: $0) })
                .frame(width: size, height: size + 66, alignment: .bottom)
                .overlay(alignment: .bottom) {
                    CartridgeShape().stroke(Color.accentColor, lineWidth: selected ? 5 : 0)
                        .frame(width: size * 0.9, height: size * 0.9 * CartridgeView.aspect)
                }
                .scaleEffect(selected ? 1.05 : 1, anchor: .bottom)
                .depthZ(selected ? 36 : 14)
                .padding(.bottom, 30)
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

// MARK: cartridge-begin (platform-neutral; also rendered on the Mac for previews)

/// A generic handheld game card outline: nearly square, a small step on the upper right edge,
/// the bottom-left corner cut at an angle, small rounded corners elsewhere.
struct CartridgeShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, c = w * 0.025
        let step = w * 0.035, stepY = h * 0.19, cut = w * 0.07
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + stepY))
        p.addLine(to: CGPoint(x: r.maxX - step, y: r.minY + stepY + step))
        p.addLine(to: CGPoint(x: r.maxX - step, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - step - c, y: r.maxY), control: CGPoint(x: r.maxX - step, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + cut, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cut))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// A light gray plastic game card with a thin raised border and a large label: the box art
/// (cropped to fit) or the icon, with a small code-style title line along the bottom. No logos.
struct CartridgeView: View {
    static let aspect: CGFloat = 1.02
    let icon: Image?
    let title: String
    let subtitle: String
    let width: CGFloat
    /// Box art, when downloaded: the label artwork.
    var art: Image? = nil

    var body: some View {
        let w = width, h = w * Self.aspect
        ZStack(alignment: .topLeading) {
            CartridgeShape()
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
            // thin raised border
            CartridgeShape()
                .stroke(Color(white: 0.97), lineWidth: max(1, w * 0.012))
                .padding(w * 0.02)
            CartridgeShape()
                .stroke(Color(white: 0.62), lineWidth: max(1, w * 0.006))
            label(w: w, h: h)
                .frame(width: w * 0.80, height: h * 0.84)
                .clipShape(RoundedRectangle(cornerRadius: w * 0.035))
                .overlay(RoundedRectangle(cornerRadius: w * 0.035).stroke(Color(white: 0.7), lineWidth: max(0.5, w * 0.004)))
                .offset(x: w * 0.075, y: h * 0.065)
            // gloss
            CartridgeShape()
                .fill(LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0),
                                             .init(color: .white.opacity(0.04), location: 0.4),
                                             .init(color: .clear, location: 0.41)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 4)
    }

    private func label(w: CGFloat, h: CGFloat) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.white
                if let art {
                    art.resizable().aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: w * 0.03) {
                        Group {
                            if let icon {
                                icon.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "gamecontroller.fill").resizable().aspectRatio(contentMode: .fit)
                                    .padding(w * 0.06).foregroundStyle(Color(white: 0.4))
                            }
                        }
                        .frame(width: w * 0.64, height: w * 0.64)
                        .clipShape(RoundedRectangle(cornerRadius: w * 0.03))
                        Text(title)
                            .font(.system(size: w * 0.07, weight: .bold))
                            .foregroundStyle(Color(white: 0.12))
                            .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                            .padding(.horizontal, w * 0.05)
                    }
                }
            }
            .frame(width: w * 0.80, height: h * 0.84 - w * 0.11)
            .clipped()
            Text(title.uppercased())
                .font(.system(size: w * 0.05, weight: .medium, design: .monospaced))
                .tracking(w * 0.004)
                .foregroundStyle(Color(white: 0.15))
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(.horizontal, w * 0.04)
                .frame(width: w * 0.80, height: w * 0.11)
                .background(Color.white)
        }
    }
}

/// The insert animation, after a real handheld: a closed console is flipped over so its underside
/// faces you with the back-edge slot on top; the card, label toward you, slides straight down in,
/// overshoots a touch, clicks, springs back flush, and the console flips back. Phases: 0 shelf,
/// 1 lifted, 2 held close, 3 console shown closed lying back, 4 console stood upright underside-toward-you + card aligned above the top slot, 5 glide (85%),
/// 6 overshoot, 7 flush, 8 console turned 180 about its vertical axis, still upright, to show its closed front,
/// 9 lid hinged open (both screens dark, buttons on the lower half), 10 screens lit, 11 zoomed so the
/// top screen fills the window width (where the game windows appear) while the body fades out.
/// Stereo depth via SwiftUI z-offsets only.
struct InsertAnimationView: View {
    let icon: Image?
    let title: String
    let subtitle: String
    let art: Image?
    let width: CGFloat
    let phase: Int
    var start: CGRect? = nil

    var body: some View {
        GeometryReader { g in
            let cx = g.size.width / 2
            let bodyW = min(g.size.width * 0.62, width * 2.6)
            let bodyH = bodyW * 0.58                          // New 3DS XL closed: 160 × 93 × 22 mm
            let bodyY = g.size.height * 0.62
            let slotY = bodyY - bodyH / 2 + 2                 // slot line on the back edge (top when flipped)
            // The card to scale with the console: 35 mm of a 160 mm wide body.
            let cartS: CGFloat = bodyW * 0.22 / width
            let slotX = cx - bodyW / 2 + bodyW * ClosedConsole.slotX
            let cartH = width * CartridgeView.aspect * cartS
            let mid = CGPoint(x: cx, y: g.size.height * 0.34)
            let from = start.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: mid.x, y: g.size.height * 0.45)
            let fromScale = start.map { $0.width / width } ?? 0.85
            let phase = min(phase, 11)
            let p = min(phase, 8)
            let ins: [CGFloat] = [0, 0, 0, -0.6, -0.12, 0.80, 0.97, 0.93, 0.93]   // flush leaves only the top edge showing   // how far the contacts end is past the slot, in cart heights
            let alignedY = slotY + cartH * ins[p] - cartH / 2
            let pos: CGPoint = p == 0 ? from : p == 1 ? CGPoint(x: from.x, y: from.y - 50) : p == 2 ? mid
                : CGPoint(x: slotX, y: alignedY)
            let scale: CGFloat = p == 0 || p == 1 ? fromScale : p == 2 ? 1 : cartS
            let z: CGFloat = [14, 70, 150, 90, 60, 50, 46, 48, 40][p]
            let flipped = p >= 3 && p <= 7   // back (slot) side to you while the cart goes in
            ZStack {
                Color.clear   // nothing behind the console: the shelf is gone
                ZStack {
                    // Spins 180° about its vertical axis, staying upright: the underside turns away
                    // as the closed front turns toward you; faces swap edge-on mid-spin.
                    ClosedConsole(width: bodyW, height: bodyH, underside: false)
                        .rotation3DEffect(.degrees(p >= 8 ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                        .opacity(flipped ? 0 : 1)
                    ClosedConsole(width: bodyW, height: bodyH, underside: true)
                        .rotation3DEffect(.degrees(p >= 8 ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                        .opacity(flipped ? 1 : 0)
                }
                .depthZ(24)
                .position(x: cx, y: bodyY)
                .opacity(p < 3 || phase >= 8 ? 0 : 1)   // from the spin on, the RealityKit console takes over
                .offset(y: p < 3 ? 60 : 0)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                CartridgeView(icon: icon, title: title, subtitle: subtitle, width: width, art: art)
                    .rotation3DEffect(.degrees(p == 1 || p == 2 ? 8 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                    .scaleEffect(scale)
                    .depthZ(z)
                    .position(pos)
                    .shadow(color: .black.opacity(0.4), radius: p == 2 ? 24 : 6, y: p == 2 ? 16 : 4)
                    .mask(alignment: .top) {   // below the slot line it is inside the console
                        Rectangle().frame(height: p >= 4 ? slotY : g.size.height * 2)
                    }
                    .opacity(p == 8 ? 0 : 1)
                #if os(visionOS)
                // Real 3D from the spin on: flies out of the window toward you, opens, glides back.
                Console3DView(phase: phase, startCenter: CGPoint(x: cx - g.size.width / 2, y: g.size.height / 2 - bodyY),
                              startWidth: bodyW, windowWidth: g.size.width, windowHeight: g.size.height)
                    .allowsHitTesting(false)
                #endif
            }
        }
    }
}

/// The opened generic clamshell: a lid with the wide top screen above a base with the smaller
/// touch screen, circle pad, D-pad, four face buttons, start/select and a power/home row.
/// Plain shapes, no logos or marks. `half` is the height of each half; the hinge is at the
/// vertical center of the view, which is 2 × half tall.
struct OpenConsole: View {
    static let topScreenW: CGFloat = 0.64
    /// Top screen center, as a fraction of `half` from the top of the lid.
    static let topScreenCY: CGFloat = 0.5
    let width: CGFloat
    let half: CGFloat
    var lidAngle: Double = 0
    var lit = false
    var shell: Double = 1

    private func screen(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(white: 0.05))
            Rectangle()
                .fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.12)],
                                     center: .center, startRadius: 0, endRadius: max(w, h) * 0.7))
                .opacity(lit ? 1 : 0)
        }
        .frame(width: w, height: h)
    }

    private func button(_ d: CGFloat) -> some View {
        Circle().fill(Color(white: 0.30)).frame(width: d, height: d)
            .overlay(Circle().strokeBorder(Color(white: 0.18), lineWidth: 0.6))
            .opacity(shell)
    }

    var body: some View {
        let w = width, h = half
        let topW = w * Self.topScreenW, topH = topW * 3 / 5
        let botW = w * 0.50, botH = botW * 3 / 4
        let shellFill = ClosedConsole.shell
        VStack(spacing: 0) {
            // lid
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.12).fill(shellFill)
                    .overlay(RoundedRectangle(cornerRadius: h * 0.12).strokeBorder(Color(red: 0.42, green: 0.03, blue: 0.05), lineWidth: 1))
                    .opacity(shell)
                RoundedRectangle(cornerRadius: h * 0.03).fill(Color(white: 0.12))
                    .frame(width: topW + h * 0.08, height: topH + h * 0.08).opacity(shell)
                screen(topW, topH)
            }
            .frame(width: w, height: h)
            .rotation3DEffect(.degrees(lidAngle), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.4)
            // base
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.12).fill(shellFill)
                    .overlay(RoundedRectangle(cornerRadius: h * 0.12).strokeBorder(Color(red: 0.42, green: 0.03, blue: 0.05), lineWidth: 1))
                    .opacity(shell)
                Capsule().fill(Color(white: 0.72)).frame(width: w * 0.9, height: h * 0.05)
                    .offset(y: -h * 0.47).opacity(shell)                                       // hinge
                RoundedRectangle(cornerRadius: h * 0.02).fill(Color(white: 0.14))
                    .frame(width: botW + h * 0.05, height: botH + h * 0.05).offset(y: -h * 0.06).opacity(shell)
                screen(botW, botH).offset(y: -h * 0.06)
                // circle pad and D-pad, left
                ZStack {
                    Circle().fill(Color(white: 0.72)).frame(width: h * 0.24, height: h * 0.24)
                    Circle().fill(Color(white: 0.40)).frame(width: h * 0.17, height: h * 0.17)
                }
                .offset(x: -w * 0.375, y: -h * 0.20).opacity(shell)
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.30)).frame(width: h * 0.07, height: h * 0.20)
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.30)).frame(width: h * 0.20, height: h * 0.07)
                }
                .offset(x: -w * 0.375, y: h * 0.12).opacity(shell)
                // face buttons, right
                ZStack {
                    button(h * 0.075).offset(y: -h * 0.075)
                    button(h * 0.075).offset(y: h * 0.075)
                    button(h * 0.075).offset(x: -h * 0.075)
                    button(h * 0.075).offset(x: h * 0.075)
                }
                .offset(x: w * 0.375, y: -h * 0.16)
                // C-stick nub above the face buttons
                Circle().fill(Color(white: 0.22)).frame(width: h * 0.045, height: h * 0.045)
                    .offset(x: w * 0.40, y: -h * 0.34).opacity(shell)
                // start / select
                VStack(spacing: h * 0.035) {
                    Capsule().fill(Color(white: 0.45)).frame(width: h * 0.09, height: h * 0.03)
                    Capsule().fill(Color(white: 0.45)).frame(width: h * 0.09, height: h * 0.03)
                }
                .offset(x: w * 0.375, y: h * 0.16).opacity(shell)
                // power / home row
                HStack(spacing: w * 0.06) {
                    Capsule().fill(Color(white: 0.62)).frame(width: w * 0.08, height: h * 0.04)
                    Circle().fill(Color(white: 0.62)).frame(width: h * 0.065, height: h * 0.065)
                    Capsule().fill(Color(white: 0.62)).frame(width: w * 0.08, height: h * 0.04)
                }
                .offset(y: h * 0.40).opacity(shell)
            }
            .frame(width: w, height: h)
        }
        .frame(width: w, height: h * 2)
    }
}

/// A closed generic clamshell handheld, light gray, no logos or buttons. The underside view puts
/// the back edge (with the centered card slot) at the top.
struct ClosedConsole: View {
    let width: CGFloat
    let height: CGFloat
    let underside: Bool
    /// The card slot on the front edge (opposite the hinge) at the far left, just over card size
    /// (card 35 mm on a 160 mm New 3DS XL-like body); fractions of the console width.
    static let slotW: CGFloat = 0.235
    static let slotX: CGFloat = 0.155
    static let shell = LinearGradient(colors: [Color(red: 0.86, green: 0.14, blue: 0.16), Color(red: 0.58, green: 0.05, blue: 0.08)],
                                      startPoint: .top, endPoint: .bottom)
    var body: some View {
        let w = width, h = height
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: h * 0.16).fill(Self.shell)
                .overlay(RoundedRectangle(cornerRadius: h * 0.16).strokeBorder(Color(red: 0.42, green: 0.03, blue: 0.05), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: h * 0.14).strokeBorder(Color.white.opacity(0.18), lineWidth: 1).padding(h * 0.03))
            if underside {
                // Base's back, front edge up: the slit at the far left, headphone jack centered,
                // stylus and power at the right. Hinge bar and L/R, ZL/ZR on the lower (back) edge.
                RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.06))
                    .frame(width: w * Self.slotW, height: max(3, h * 0.035))
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color(white: 0.45), lineWidth: 0.5))
                    .offset(x: w * (Self.slotX - 0.5)).padding(.top, h * 0.006)
                Circle().fill(Color(white: 0.08)).frame(width: h * 0.035, height: h * 0.035).padding(.top, h * 0.006)
                HStack(spacing: w * 0.03) {
                    Capsule().fill(Color(white: 0.15)).frame(width: w * 0.05, height: h * 0.03)       // power
                    Capsule().fill(Color(white: 0.75)).frame(width: w * 0.035, height: h * 0.03)      // stylus
                }
                .offset(x: w * 0.36).padding(.top, h * 0.006)
                RoundedRectangle(cornerRadius: h * 0.05).strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
                    .frame(width: w * 0.42, height: h * 0.30).padding(.top, h * 0.36)                // battery cover
                shoulders(w, h).frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                // Lid face, plain (no marks); hinge bar along the lower edge.
                Capsule().fill(Color(red: 0.40, green: 0.03, blue: 0.05)).frame(width: w * 0.78, height: h * 0.07)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, h * 0.005)
            }
        }
        .frame(width: w, height: h)
    }

    private func shoulders(_ w: CGFloat, _ h: CGFloat) -> some View {
        HStack {
            HStack(spacing: 2) { pad(w * 0.16, h); pad(w * 0.06, h) }        // L, ZL
            Spacer()
            Capsule().fill(Color(red: 0.40, green: 0.03, blue: 0.05)).frame(width: w * 0.42, height: h * 0.07)  // hinge bar
            Spacer()
            HStack(spacing: 2) { pad(w * 0.06, h); pad(w * 0.16, h) }        // ZR, R
        }
        .padding(.horizontal, w * 0.03).padding(.bottom, h * 0.004)
    }
    private func pad(_ w: CGFloat, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: h * 0.03).fill(Color(white: 0.20)).frame(width: w, height: h * 0.05)
    }
}

/// The label-less back of the card: plain light gray with a row of contacts along the bottom (inserted) edge.
struct CartridgeBack: View {
    let width: CGFloat
    var body: some View {
        let h = width * CartridgeView.aspect
        ZStack(alignment: .bottom) {
            CartridgeShape().fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.76)], startPoint: .top, endPoint: .bottom))
            CartridgeShape().stroke(Color(white: 0.6), lineWidth: 1)
            HStack(spacing: width * 0.02) {
                ForEach(0..<9, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.78, green: 0.66, blue: 0.36)).frame(width: width * 0.055, height: h * 0.10)
                }
            }
            .padding(.bottom, h * 0.05)
        }
        .frame(width: width, height: h)
    }
}


extension View {
    /// Real depth toward the viewer on visionOS (points); flat elsewhere (Mac previews).
    @ViewBuilder func depthZ(_ z: CGFloat) -> some View {
        #if os(visionOS)
        self.offset(z: z)
        #else
        self
        #endif
    }

    /// A shelf board with physical thickness on visionOS.
    @ViewBuilder func shelfDepth() -> some View {
        #if os(visionOS)
        self.frame(depth: 24).offset(z: 4)
        #else
        self
        #endif
    }
}

// MARK: cartridge-end

/// Box art from GameTDB (art.gametdb.com/3ds/coverM/<region>/<id>.jpg), looked up by the 4-letter
/// game ID in the product code (CTR-P-AREE → AREE) read from the NCCH header, cached in
/// Application Support/Covers. Without a cover (offline, homebrew, unknown) the label shows the
/// SMDH icon and title.
@MainActor
final class CoverArtStore: ObservableObject {
    static let shared = CoverArtStore()
    @Published private var images: [String: UIImage] = [:]
    private var requested: Set<String> = []

    private static let directory: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func cover(for game: Game) -> UIImage? {
        if let image = images[game.id] { return image }
        if !requested.contains(game.id) {
            requested.insert(game.id)
            let url = game.url, id = game.id
            Task.detached(priority: .utility) {
                guard let image = await Self.load(rom: url) else { return }
                await MainActor.run { self.images[id] = image }
            }
        }
        return nil
    }

    nonisolated private static func load(rom: URL) async -> UIImage? {
        guard let code = productCode(of: rom) else { return nil }
        let gameID = String(code.suffix(4))
        guard gameID.count == 4, gameID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let file = directory.appendingPathComponent("\(gameID).jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        let regions: [String]
        switch gameID.last {
        case "P", "D", "F", "S", "I", "X", "Y", "Z", "V": regions = ["EN", "US", "JA"]
        case "J": regions = ["JA", "US", "EN"]
        case "K": regions = ["KO", "US", "EN"]
        default: regions = ["US", "EN", "JA"]
        }
        for region in regions {
            guard let url = URL(string: "https://art.gametdb.com/3ds/coverM/\(region)/\(gameID).jpg") else { continue }
            var request = URLRequest(url: url)
            request.setValue("Holofold", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { continue }
            try? data.write(to: file, options: .atomic)
            VisionDiag.log("cover: \(code) from \(region)")
            return image
        }
        VisionDiag.log("cover: none for \(code)")
        return nil
    }

    /// "CTR-P-AREE" from a .3ds/.cci (NCSD, first partition) or .cxi/.app (NCCH) header.
    nonisolated static func productCode(of rom: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: rom) else { return nil }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            (try? h.seek(toOffset: offset)).flatMap { _ in try? h.read(upToCount: count) }
        }
        guard let head = read(0x100, 0x30), head.count == 0x30 else { return nil }
        let magic = String(decoding: head.prefix(4), as: UTF8.self)
        var ncch: UInt64 = 0
        if magic == "NCSD" {
            let units = head[head.startIndex + 0x20 ..< head.startIndex + 0x24].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            ncch = UInt64(UInt32(littleEndian: units)) * 0x200
            guard let m = read(ncch + 0x100, 4), String(decoding: m, as: UTF8.self) == "NCCH" else { return nil }
        } else if magic != "NCCH" {
            return nil
        }
        guard let raw = read(ncch + 0x150, 16) else { return nil }
        let code = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        return code.hasPrefix("CTR-") || code.hasPrefix("KTR-") ? code : nil
    }
}

/// A wooden shelf with a glass edge, as in FlycastVision.
private struct Shelf: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.38, blue: 0.24).opacity(0.95),
                                          Color(red: 0.36, green: 0.23, blue: 0.13).opacity(0.95)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.22)).frame(height: 3).padding(.horizontal, 4).padding(.top, 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 10, y: 8)
            .shelfDepth()
    }
}

/// Moves the shelf selection with any controller's d-pad or left stick; A / ✕ plays it.
@MainActor
private final class LibraryNavigator: ObservableObject {
    @Published var selected = 0
    private var count: () -> Int = { 0 }
    private var columns = 4
    private var play: (Int) -> Void = { _ in }
    private var stickReady = true

    func setColumns(_ n: Int) { columns = n }

    func attach(count: @escaping () -> Int, columns: Int, play: @escaping (Int) -> Void) {
        // Never take the pads from a running game (a controller connecting while playing).
        if az_is_running() { return }
        self.count = count
        self.columns = columns
        self.play = play
        for c in GCController.controllers() {
            guard let pad = c.extendedGamepad else { continue }
            // Remember the game's bindings so leaving the library hands them back intact.
            if saved[ObjectIdentifier(pad)] == nil { saved[ObjectIdentifier(pad)] = (pad.dpad.valueChangedHandler, pad.leftThumbstick.valueChangedHandler, pad.buttonB.pressedChangedHandler) }
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in self?.move(x: x, y: y) }
            }
            pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in self?.stick(x: x, y: y) }
            }
            // Confirm with the east button (Circle), which is 3DS A by position, as in game.
            pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.activate() }
            }
        }
    }

    private var saved: [ObjectIdentifier: (GCControllerDirectionPadValueChangedHandler?, GCControllerDirectionPadValueChangedHandler?, GCControllerButtonValueChangedHandler?)] = [:]

    func detach() {
        for c in GCController.controllers() {
            guard let pad = c.extendedGamepad else { continue }
            // Only pads this navigator took over: a second detach (insert, then onDisappear) used
            // to restore nothing and wipe the game's stick and A bindings.
            guard let old = saved[ObjectIdentifier(pad)] else { continue }
            pad.dpad.valueChangedHandler = old.0
            pad.leftThumbstick.valueChangedHandler = old.1
            pad.buttonB.pressedChangedHandler = old.2
            saved[ObjectIdentifier(pad)] = nil
        }
        // The boot window closes after the game window bound the pads, so what was saved here can
        // be stale or empty: that left the circle pad, D-pad and A dead in game. Bind them again.
        Task { @MainActor in InputManager.shared.reattachIfActive("library closed") }
    }

    private func stick(x: Float, y: Float) {
        if abs(x) < 0.3 && abs(y) < 0.3 { stickReady = true; return }
        guard stickReady, abs(x) > 0.7 || abs(y) > 0.7 else { return }
        stickReady = false
        move(x: abs(x) > abs(y) ? x : 0, y: abs(y) >= abs(x) ? y : 0)
    }

    private func move(x: Float, y: Float) {
        let n = count()
        guard n > 0 else { return }
        var i = selected
        if x > 0.5 { i += 1 } else if x < -0.5 { i -= 1 }
        else if y > 0.5 { i -= columns } else if y < -0.5 { i += columns }
        else { return }
        selected = min(max(i, 0), n - 1)
    }

    private func activate() {
        let n = count()
        guard n > 0 else { return }
        play(min(selected, n - 1))
    }
}
#endif

#if os(visionOS)
/// The insert animation's console as real RealityKit geometry: a clamshell (base with the touch
/// screen, circle pad, D-pad and face buttons in relief; a lid on a hinge with the top screen).
/// Driven by the insert phases: 8 flies out ~50 cm toward you spinning to face you (overshoot),
/// 9 pops the lid open (overshoot), 10 lights the screens, 11 glides back into the window plane
/// while the top screen grows to the window width. Built once; a dozen primitives, no textures,
/// no input targets (taps and the controller still go to the shelf).
struct Console3DView: View {
    let phase: Int
    let startCenter: CGPoint   // points from the view center, y up
    let startWidth: CGFloat    // points
    let windowWidth: CGFloat   // points
    let windowHeight: CGFloat  // points
    @AppStorage(VisionStereo.curvedKey) private var curved = true
    @AppStorage(VisionStereo.topSizeKey) private var topSize = 1.0
    @AppStorage(VisionStereo.bottomSizeKey) private var bottomSize = 1.0
    @PhysicalMetric(from: .meters) private var ptPerM = 1.0
    @State private var rig = Console3DRig()

    var body: some View {
        RealityView { content in
            content.add(rig.root)
        }
        .preferredWindowClippingMargins(.all, ptPerM * 0.7)
        .onAppear { drive(phase) }
        .onChange(of: phase) { _, p in drive(p) }
    }

    private func drive(_ p: Int) {
        let m = Float(1 / max(ptPerM, 1))
        rig.apply(phase: p, start: SIMD3(Float(startCenter.x) * m, Float(startCenter.y) * m, 0),
                  startWidth: Float(startWidth) * m, windowWidth: Float(windowWidth) * m,
                  windowHeight: Float(windowHeight) * m, curved: curved, topSize: Float(topSize), bottomSize: Float(bottomSize))
    }
}

@MainActor final class Console3DRig {
    static let w: Float = 0.16, h: Float = 0.093, tb: Float = 0.012, tl: Float = 0.010
    static let topW: Float = 0.106, topH: Float = 0.064
    let root = Entity()
    let body = Entity()
    let hinge = Entity()
    let topScreen: ModelEntity
    let bottomScreen: ModelEntity
    private var shown = -1
    private var gen = 0
    private static let dark = UnlitMaterial(color: UIColor(white: 0.04, alpha: 1))
    private static let lit = UnlitMaterial(color: VisionGameSession.holdColor)   // dim neutral, same as the game window's hold

    init() {
        let shell = SimpleMaterial(color: UIColor(red: 0.62, green: 0.07, blue: 0.10, alpha: 1), roughness: 0.35, isMetallic: true)
        let inner = SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.6, isMetallic: false)
        let key = SimpleMaterial(color: UIColor(white: 0.22, alpha: 1), roughness: 0.4, isMetallic: false)
        let W = Self.w, H = Self.h, TB = Self.tb, TL = Self.tl
        func box(_ x: Float, _ y: Float, _ z: Float, _ r: Float, _ mat: RealityKit.Material) -> ModelEntity {
            ModelEntity(mesh: .generateBox(width: x, height: y, depth: z, cornerRadius: r), materials: [mat])
        }
        func knob(_ d: Float, _ t: Float, _ mat: RealityKit.Material, _ at: SIMD3<Float>) -> ModelEntity {
            let e = ModelEntity(mesh: .generateCylinder(height: t, radius: d / 2), materials: [mat])
            e.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            e.position = at
            return e
        }
        // Base: a slab in the x-y plane, its face (+z) toward you; hinge along its top edge.
        let base = box(W, H, TB, 0.006, shell)
        let face = box(W - 0.006, H - 0.006, 0.001, 0.003, inner); face.position = [0, 0, TB / 2]
        base.addChild(face)
        bottomScreen = box(0.085, 0.064, 0.0012, 0.001, Self.dark); bottomScreen.position = [0, 0.004, TB / 2 + 0.0008]
        base.addChild(bottomScreen)
        let zf = TB / 2 + 0.002
        base.addChild(knob(0.018, 0.004, key, [-0.064, 0.022, zf]))                       // circle pad
        let dh = box(0.016, 0.005, 0.004, 0.001, key); dh.position = [-0.064, -0.012, zf]
        let dv = box(0.005, 0.016, 0.004, 0.001, key); dv.position = [-0.064, -0.012, zf]
        base.addChild(dh); base.addChild(dv)                                                // D-pad
        for (dx, dy) in [(0, 0.008), (0, -0.008), (-0.008, 0), (0.008, 0)] as [(Float, Float)] {
            base.addChild(knob(0.0065, 0.004, key, [0.064 + dx, 0.012 + dy, zf]))          // face buttons
        }
        for x in [-0.012, 0.0, 0.012] as [Float] {
            base.addChild(knob(0.004, 0.002, key, [x, -H / 2 + 0.006, TB / 2 + 0.001]))    // home row
        }
        body.addChild(base)
        // Lid on the hinge: open it stands above the base (+y), closed it folds down over the face.
        let lid = box(W, H, TL, 0.006, shell); lid.position = [0, H / 2, 0]
        let lidFace = box(W - 0.006, H - 0.006, 0.001, 0.003, inner); lidFace.position = [0, 0, TL / 2]
        lid.addChild(lidFace)
        topScreen = box(Self.topW, Self.topH, 0.0012, 0.001, Self.dark); topScreen.position = [0, 0, TL / 2 + 0.0008]
        lid.addChild(topScreen)
        hinge.addChild(lid)
        hinge.position = [0, H / 2, TB / 2 + TL / 2]
        hinge.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])   // closed
        body.addChild(hinge)
        root.addChild(body)
        root.isEnabled = false
    }

    private func later(_ t: Double, _ g: Int, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in if self?.gen == g { f() } }
    }
    private func move(_ e: Entity, _ t: Transform, _ d: Double, _ tf: AnimationTimingFunction = .easeInOut) {
        e.move(to: t, relativeTo: e.parent, duration: d, timingFunction: tf)
    }
    private func lidTo(_ deg: Float, _ d: Double, _ tf: AnimationTimingFunction) {
        var t = hinge.transform; t.rotation = simd_quatf(angle: deg * .pi / 180, axis: [1, 0, 0])
        move(hinge, t, d, tf)
    }

    func apply(phase: Int, start: SIMD3<Float>, startWidth: Float, windowWidth: Float,
               windowHeight: Float, curved: Bool, topSize: Float, bottomSize: Float) {
        guard phase != shown else { return }
        shown = phase
        gen += 1
        let g = gen
        let yaw = { (deg: Float) in simd_quatf(angle: deg * .pi / 180, axis: [0, 1, 0]) }
        switch phase {
        case 8:
            // From where the flat console sat (back to you, as the card went in): out toward you.
            root.isEnabled = true
            body.transform = Transform(scale: .init(repeating: startWidth / Self.w), rotation: yaw(180), translation: start)
            // Sized so the opened console (base + upright lid = 2 H tall) fits well inside the window,
            // centered on it, and only a little toward you: nothing reaches the window's edges.
            let s = min(0.30 / Self.w, windowWidth * 0.55 / Self.w, windowHeight * 0.70 / (2 * Self.h))
            let out = SIMD3<Float>(0, -Self.h / 2 * s, 0.12)
            move(body, Transform(scale: .init(repeating: s * 1.04), rotation: yaw(-14) * simd_quatf(angle: 0.12, axis: [1, 0, 0]), translation: out), 0.52, .easeOut)
            later(0.52, g) { self.move(self.body, Transform(scale: .init(repeating: s), rotation: simd_quatf(angle: 0.10, axis: [1, 0, 0]), translation: out), 0.18, .easeInOut) }
        case 9:
            lidTo(70, 0.18, .easeIn)
            later(0.18, g) { self.lidTo(-34, 0.18, .easeOut) }
            later(0.35, g) { self.lidTo(-25, 0.13, .easeInOut) }
        case 10:
            topScreen.model?.materials = [Self.lit]
            bottomScreen.model?.materials = [Self.lit]
        case 11:
            // Real-3DS opening finished: lid upright on the hinge, then the console's shell fades while
            // its two lit screens slide and stretch to exactly where the game window (opened in this
            // window's place and size) lays out its top and touch screens (layoutScreens).
            root.isEnabled = true
            lidTo(0, 0.24, .easeOut)
            let tilt = VisionStereo.touchTiltDegrees * .pi / 180
            let ts = min(max(topSize, 0.5), 1.5), bs = min(max(bottomSize, 0.5), 1.5)
            let width = windowWidth, height = windowHeight * 0.94
            let bScale = VisionGameSession.bottomScale
            let defaultTotal = 0.6 + 0.03 + bScale * 0.75 * cos(tilt)
            var unit = min(width, height / defaultTotal)
            var tw = ts, bw = bScale * bs
            let total = tw * 0.6 + 0.03 + bw * 0.75 * cos(tilt)
            unit *= min(1, width / (unit * max(tw, bw)), height / (unit * total))
            tw *= unit; bw *= unit
            let span = unit * total
            let topDrawnW = min(tw, tw * 0.6 * 5 / 3) * (curved ? 0.88 : 1)
            let topT = Transform(scale: [topDrawnW / Self.topW, topDrawnW * 0.6 / Self.topH, 1],
                                 rotation: simd_quatf(angle: 0, axis: [0, 1, 0]),
                                 translation: [0, span / 2 - tw * 0.3, 0])
            let botT = Transform(scale: [bw / 0.085, bw * 0.75 / 0.064, 1],
                                 rotation: simd_quatf(angle: -tilt, axis: [1, 0, 0]),
                                 translation: [0, -span / 2 + bw * 0.75 / 2 * cos(tilt), 0])
            later(0.24, g) {
                for (e, t) in [(self.topScreen as Entity, topT), (self.bottomScreen as Entity, botT)] {
                    e.setParent(self.root, preservingWorldTransform: true)
                    e.move(to: t, relativeTo: self.root, duration: 0.44, timingFunction: .easeInOut)
                }
                self.body.components.set(OpacityComponent(opacity: 1))
                let fade = FromToByAnimation<Float>(from: 1, to: 0, duration: 0.36, timing: .easeIn, bindTarget: .opacity)
                if let res = try? AnimationResource.generate(with: fade) { self.body.playAnimation(res) }
                else { self.body.isEnabled = false }
            }
        default:
            break
        }
    }
}
#endif
