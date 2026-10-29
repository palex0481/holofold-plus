#if os(visionOS)
import SwiftUI

/// What the app around the game engine does at the edges of a session. The engine (game and
/// touch windows) only talks to the shell through this, so it works the same with the minimal
/// public shell, which boots straight into a game, and with an app that has a launcher.
@MainActor
protocol VisionShell {
    /// The game and touch windows are open and the game is booting.
    func gameDidStart(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction)
    /// The game stopped and its windows are closing.
    func gameDidEnd(openWindow: OpenWindowAction)
    /// The system brought back a game window without a usable request.
    func recoverFromOrphanWindow(openWindow: OpenWindowAction)
}

@MainActor
enum VisionShellRegistry {
    /// Set once at launch by the app's entry point.
    static var current: VisionShell = MinimalShell()
}

/// The public build's shell: the library (boot) window closes once the game windows are up and
/// comes back when the game ends.
struct MinimalShell: VisionShell {
    func gameDidStart(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        dismissWindow(id: VisionWindowID.boot)
    }

    /// Back to the library.
    func gameDidEnd(openWindow: OpenWindowAction) {
        openWindow(id: VisionWindowID.boot)
    }

    func recoverFromOrphanWindow(openWindow: OpenWindowAction) {
        openWindow(id: VisionWindowID.boot)
    }
}
#endif
