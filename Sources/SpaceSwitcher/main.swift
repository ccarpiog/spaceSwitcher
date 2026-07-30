import AppKit

/// Entry point. The app has no dock icon and no menu bar item by design — the
/// hotkey is the whole interface — so it is set up programmatically rather than
/// from a storyboard.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = SwitcherController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    /// Keeps the process alive with no windows open, which is the normal state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Holds the launch sequence on the main actor.
///
/// `NSApplication.delegate` is a weak reference, so the delegate is a `static let`
/// here rather than a local: a local would be released the moment setup returned,
/// leaving the app with no delegate and no hotkey.
@MainActor
enum AppLauncher {

    static let delegate = AppDelegate()

    /// Configures the shared application and enters its run loop.
    static func run() {
        let app = NSApplication.shared
        app.delegate = delegate
        // `.accessory` gives no dock icon and no menu bar, matching LSUIElement.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// Top-level code is not main-actor isolated in Swift 5 language mode, but it does
// run on the main thread, and `NSApplication` must be created and run
// synchronously here — so the isolation is asserted rather than hopped to.
MainActor.assumeIsolated {
    AppLauncher.run()
}
