import AppKit
import Combine

/// The optional menu bar presence: an `NSStatusItem` that exists only while
/// `Preferences.showsMenuBarIcon` is on.
///
/// It is also the app's only proper way out. An `.accessory` app has no dock icon
/// and no menu bar of its own, so there is nowhere else to hang a Quit command —
/// until now the only alternative was killing the process.
@MainActor
final class MenuBarController: NSObject {

    /// Brings the Spaces panel up.
    var onShowPanel: (() -> Void)?
    /// Opens the Settings window.
    var onOpenSettings: (() -> Void)?

    private let preferences: Preferences
    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?

    /// - Parameter preferences: the store to follow. Passed in rather than
    ///   defaulted to `.shared`: a default argument is evaluated in a nonisolated
    ///   context, which cannot touch a main-actor-isolated `static let`.
    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    /// Starts following the preference. Called once the app has finished
    /// launching, rather than from the initialiser, so nothing touches the status
    /// bar before `NSApplication` is running.
    ///
    /// Subscribing is all it takes to get the initial state too: `@Published` hands
    /// the current value to a new subscriber, so an icon that should already be
    /// there at launch appears without a separate call.
    func start() {
        guard observation == nil else { return }
        observation = preferences.$showsMenuBarIcon.sink { [weak self] isVisible in
            // Isolation is asserted, not hopped to, and that is only sound because
            // `Preferences` is `@MainActor`: a `@Published` value is delivered on
            // the thread that assigned it, so every emission necessarily arrives on
            // the main actor. Were the store ever de-isolated this would have to
            // become a real hop — `assumeIsolated` traps, it does not switch.
            MainActor.assumeIsolated { self?.setVisible(isVisible) }
        }
    } // End of start()

    /// Creates or tears down the status item so the toggle takes effect
    /// immediately. Idempotent, since the publisher also fires on subscription.
    ///
    /// - Parameter isVisible: the state the menu bar should end up in.
    private func setVisible(_ isVisible: Bool) {
        guard isVisible != (statusItem != nil) else { return }

        if isVisible {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(
                systemSymbolName: "rectangle.3.group",
                accessibilityDescription: NSLocalizedString(
                    "menu.icon.description",
                    comment: "Accessibility description of the menu bar icon"))
            item.menu = makeMenu()
            statusItem = item
        } else if let statusItem {
            // Handing the item back to the status bar is what removes it. Dropping
            // the reference alone leaves the icon sitting in the menu bar.
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    } // End of setVisible(_:)

    /// Builds the item's menu: reach the panel, reach Settings, leave.
    ///
    /// No key equivalents. They would only fire while this menu is open, and
    /// printing `⌘Q` next to Quit in an app that does not own a menu bar promises
    /// a shortcut that does nothing anywhere else.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(item(NSLocalizedString(
            "menu.showPanel", comment: "Menu bar entry that opens the Spaces panel"),
            action: #selector(showPanel)))
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString(
            "menu.settings", comment: "Menu bar entry that opens the Settings window"),
            action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString(
            "menu.quit", comment: "Menu bar entry that quits the app"),
            action: #selector(quit)))

        return menu
    } // End of makeMenu()

    /// One menu entry, targeted at this object.
    ///
    /// - Parameters:
    ///   - title: the visible, already localised title.
    ///   - action: selector invoked when the entry is chosen.
    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    /// Menu action: show the Spaces panel.
    @objc private func showPanel() { onShowPanel?() }

    /// Menu action: open Settings.
    @objc private func openSettings() { onOpenSettings?() }

    /// Menu action: quit. The app keeps running with no windows open, so this is
    /// the deliberate way to end it.
    @objc private func quit() { NSApp.terminate(nil) }
}
