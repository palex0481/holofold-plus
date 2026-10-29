#if os(visionOS)
import AVFoundation
import SwiftUI
import GameController

/// The game's one window, shared by every entry point: the top screen in stereo with the bottom
/// screen below it, both in the same RealityView (no separate touch window).
struct VisionGameScenes: Scene {
    var body: some Scene {
        // Never restored: a game window brought back on the next launch would boot the game a
        // second time (seen on the device as three windows).
        WindowGroup(id: VisionWindowID.game, for: VisionGameRequest.self) { $request in
            if let request {
                VisionGameWindow(request: request)
            } else {
                // Restored by the system with no (or an outdated) request: an empty window.
                VisionOrphanWindow()
            }
        }
        .windowStyle(.plain)
        // Lower than before (was 2600 x 2500): visionOS centers a new window at eye level and has no
        // vertical-offset placement (WindowPlacement.Position offers only replacing / above / below /
        // leading / trailing / utilityPanel), so a shorter window is what brings its top edge down.
        .defaultSize(width: 2000, height: 1700)
        // From the shelf: exactly in the shelf window's place and size, so the insert animation's
        // screens (laid out for that size) land where the game's screens appear. Resizable after.
        .defaultWindowPlacement { _, context in
            if let size = VisionLaunchGeometry.shelfSize,
               let shelf = context.windows.first(where: { $0.id == VisionWindowID.boot }) {
                // Shelf height, screens' width: no empty sides, same screen positions as the animation.
                return WindowPlacement(.replacing(shelf),
                                       size: CGSize(width: VisionLaunchGeometry.screensWidth(for: size), height: size.height))
            }
            let fallback = CGSize(width: 2000, height: 1700)
            return WindowPlacement(size: CGSize(width: VisionLaunchGeometry.screensWidth(for: fallback), height: fallback.height))
        }
        // Resizable from a corner; the content keeps the stacked screens' aspect (see VisionGameWindow).
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

    }
}

/// Process setup every entry point does once.
@MainActor
enum VisionAppSetup {
    static func run() {
        GCController.shouldMonitorBackgroundEvents = true  // local: input keeps flowing when another app window has focus

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // 2D and Immersive modes were removed: always stereo 3D in a window. Drop their old picks.
        for key in [VisionStereo.depthKey, "visionImmersiveMode", "visionImmersiveScale"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        EmulatorCore.shared.initialize()
    }
}
#endif
