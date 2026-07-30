import AppKit
import SwiftUI

/// The Settings window.
///
/// It is a subclass for one reason: an `.accessory` app owns no menu bar, so
/// nothing claims `⌘,` on its behalf. Without this the standard shortcut for
/// "open settings" would beep at the user while the Settings window is in front.
final class SettingsWindow: NSWindow {

    /// Handles the two shortcuts no menu bar is here to claim: `⌘,` and `⌘W`.
    /// Everything else takes the usual route.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The window that shortcut would open is this one, and it is already key,
        // so recognising it is the whole behaviour.
        if event.isSettingsShortcut { return true }
        // Without a menu bar there is no File ▸ Close, so `⌘W` would beep and the
        // window could only be dismissed with the mouse.
        if event.isCloseWindowShortcut {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    } // End of performKeyEquivalent(with:)
}

/// Owns the one Settings window there is.
///
/// Shared rather than built on demand: asking for Settings twice must bring the
/// existing window forward, not stack a second copy behind the first.
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: SettingsWindow?

    private init() {}

    /// Brings Settings up, building the window the first time it is asked for.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        // Asked for here as well as from the view's `onAppear`: the window is kept
        // alive between showings, so a second `show()` re-orders a view hierarchy
        // that never went away and never appears again.
        LoginItemController.shared.refresh()

        // Activating is not optional. The app is `.accessory`, so ordering a window
        // front without activating leaves it drawn but unable to become key — the
        // same reason the HUD panel activates before it appears.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Builds the window and hosts the SwiftUI settings inside it.
    private func makeWindow() -> SettingsWindow {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)

        window.title = NSLocalizedString("settings.title",
                                         comment: "Title of the Settings window")
        // Closing has to leave the window reusable. The default is to deallocate it
        // on close, after which the next `show()` would message a freed object.
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 400)
        // Follow the user rather than drag them somewhere else. This app exists to
        // move between Spaces, so a Settings window pinned to whichever Space it
        // was first opened on would throw them off the one they are working in.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: SettingsView(preferences: .shared,
                                                                  hotKeys: .shared,
                                                                  loginItem: .shared))
        window.center()

        return window
    } // End of makeWindow()
}

extension NSEvent {

    /// Whether this key event is `⌘,`, the system-wide gesture for opening
    /// settings. Exactly `⌘` — `⌘⇧,` and friends belong to whoever else wants them.
    var isSettingsShortcut: Bool {
        commandOnly && charactersIgnoringModifiers == ","
    }

    /// Whether this key event is `⌘W`, the system-wide gesture for closing a
    /// window. Case-insensitive: `charactersIgnoringModifiers` reports "W" when
    /// Caps Lock is on.
    var isCloseWindowShortcut: Bool {
        commandOnly && charactersIgnoringModifiers?.lowercased() == "w"
    }

    /// Whether `⌘` is the only modifier held, ignoring Caps Lock.
    ///
    /// Caps Lock has to be masked out explicitly: it lives inside
    /// `deviceIndependentFlagsMask`, so comparing that intersection against
    /// `.command` says "no" to every one of these shortcuts while Caps Lock
    /// happens to be on. Every other modifier still disqualifies the event —
    /// `⌘⇧,` and friends belong to whoever else wants them.
    private var commandOnly: Bool {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock) == .command
    }
}
