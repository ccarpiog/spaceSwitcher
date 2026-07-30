import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the hotkey, the panel and the switching engine, and wires them together.
@MainActor
final class SwitcherController {

    private let enumerator = SpaceEnumerator()
    private let engine = SpaceSwitchEngine()
    private let model = HUDViewModel()
    private let menuBar = MenuBarController(preferences: .shared)

    private var hotKey: GlobalHotKey?
    private var panel: HUDPanel?
    private var keyMonitor: Any?
    /// The app that was frontmost before the panel opened, restored on cancel so
    /// dismissing the HUD leaves the session exactly as it was.
    private var previousApp: NSRunningApplication?

    /// Default hotkey: `Ctrl+Option+Space`. Chosen to avoid the system's own
    /// bindings — `Cmd+Ctrl+Space` is the Character Viewer, `Ctrl+Space` the
    /// input-source switcher.
    private static let defaultKeyCode = UInt32(kVK_Space)
    private static let defaultModifiers = UInt32(controlKey | optionKey)

    /// Name of the distributed notification that opens the panel.
    ///
    /// A second way in, besides the hotkey: it lets the panel be opened from
    /// Shortcuts, Alfred, Raycast or a shell one-liner, and makes the UI testable
    /// without depending on synthesized key events reaching the hotkey machinery.
    ///
    ///     notifyutil -p cc.carpio.spaceSwitcher.toggle
    static let toggleNotification = "cc.carpio.spaceSwitcher.toggle"

    /// Registers the global hotkey and the notification trigger. Called once at launch.
    func start() {
        let key = GlobalHotKey(keyCode: SwitcherController.defaultKeyCode,
                               modifiers: SwitcherController.defaultModifiers)
        key.onPress = { [weak self] in self?.toggle() }
        hotKey = key

        // The status item comes and goes with the preference on its own; all it
        // needs from here is what its entries should do.
        menuBar.onShowPanel = { [weak self] in self?.present() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.start()

        // Two notification systems, because they are genuinely distinct and each
        // is the natural choice for a different caller:
        //
        //   Darwin      — what `notifyutil -p` posts, so shell scripts work.
        //   Distributed — what other apps and Shortcuts post via Cocoa.
        //
        // Registering only one silently ignores half the callers.
        // `notify_register_dispatch` is not exposed to Swift, so the Darwin centre
        // is reached through CoreFoundation. Its callback is a C function pointer
        // and cannot capture context, hence the round trip through an opaque
        // pointer to self.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<SwitcherController>
                    .fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { controller.toggle() }
                }
            },
            SwitcherController.toggleNotification as CFString,
            nil,
            .deliverImmediately
        )

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(SwitcherController.toggleNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
    } // End of start()

    // MARK: - Panel lifecycle

    /// Shows the panel, or hides it if it is already up.
    private func toggle() {
        if panel?.isVisible == true {
            dismiss(restoringFocus: true)
        } else {
            present()
        }
    }

    /// Refreshes the Space list and brings the panel up.
    private func present() {
        // The only case with genuinely nothing to show: the Spaces layout is
        // unreadable, so there is no list to fall back on.
        guard SkyLightBridge.shared.isAvailable else {
            model.fatalMessage = NSLocalizedString(
                "error.unsupported",
                comment: "Shown when the private SkyLight symbols cannot be resolved")
            showPanel()
            return
        }

        model.fatalMessage = nil
        model.displays = enumerator.enumerate()
        model.selectDefault()

        // Only an outright refusal is worth a warning. `.notDetermined` just means
        // the app has not asked yet, and the prompt will appear on the first jump —
        // warning about it would make a normal first launch look broken.
        model.notice = engine.automationStatus(prompting: false) == .denied
            ? NSLocalizedString("error.automation",
                                comment: "Shown when Automation permission has been refused")
            : nil

        showPanel()
    } // End of present()

    /// Builds the panel if needed, sizes it to its contents and makes it key.
    ///
    /// The app is activated deliberately: only the frontmost application's
    /// windows receive key events, so a non-activating panel alone would render
    /// but never respond to the keyboard.
    private func showPanel() {
        let view = HUDView(
            model: model,
            onChoose: { [weak self] row in self?.choose(row) },
            onOpenSettings: { [weak self] in self?.openSettings() })
        let hosting = NSHostingView(rootView: view)

        let existing = panel ?? HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200))
        existing.onCancel = { [weak self] in self?.dismiss(restoringFocus: true) }
        existing.contentView = hosting
        existing.setContentSize(hosting.fittingSize)
        existing.centreOnActiveScreen()
        panel = existing

        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        existing.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    } // End of showPanel()

    /// Tears the panel down, optionally handing focus back where it came from.
    ///
    /// - Parameter restoringFocus: `true` when the user cancelled, so the app
    ///   they were using regains focus. `false` after a jump, where the target
    ///   Space should decide what is focused.
    private func dismiss(restoringFocus: Bool) {
        removeKeyMonitor()
        panel?.orderOut(nil)
        if restoringFocus, let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    // MARK: - Settings

    /// Opens the Settings window, closing the panel on the way if it is up.
    ///
    /// Focus is deliberately not restored to the previous app: it is about to go to
    /// the Settings window instead, and handing it back first would raise the other
    /// app over the window that was just asked for.
    private func openSettings() {
        dismiss(restoringFocus: false)
        SettingsWindowController.shared.show()
    }

    // MARK: - Keyboard handling

    /// Starts intercepting key presses while the panel is up.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Stops intercepting key presses.
    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Interprets one key press.
    ///
    /// - Returns: `true` when the event was consumed and must not propagate.
    private func handle(_ event: NSEvent) -> Bool {
        // The monitor is app-wide, so it has to stay out of the way of the app's
        // other windows: with Settings in front, `q` is a letter someone is typing,
        // not a request to quit. A nil key window is left alone rather than
        // treated as "not the panel" — that is the state the panel itself is in
        // for the instant between being ordered front and becoming key.
        if let keyWindow = NSApp.keyWindow, keyWindow !== panel { return false }

        // `⌘,` has to be recognised here. An `.accessory` app has no menu bar, so
        // there is no Settings menu item to own the shortcut.
        if event.isSettingsShortcut {
            openSettings()
            return true
        }

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            model.moveSelection(by: 1)
            return true
        case kVK_UpArrow:
            model.moveSelection(by: -1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commitSelection()
            return true
        case kVK_Escape:
            dismiss(restoringFocus: true)
            return true
        case kVK_ANSI_Q:
            NSApp.terminate(nil)
            return true
        default:
            break
        }

        // Digits jump straight to a row.
        if let characters = event.charactersIgnoringModifiers,
           let digit = Int(characters), digit >= 1, digit <= 9,
           digit <= model.rows.count {
            model.selection = digit - 1
            commitSelection()
            return true
        }
        return false
    } // End of handle(_:)

    /// Acts on whatever row is currently highlighted.
    ///
    /// Deliberately not gated on `notice`: a permission warning must not stop the
    /// user selecting a Space, since attempting the jump is what triggers the
    /// permission prompt in the first place.
    private func commitSelection() {
        guard model.fatalMessage == nil,
              model.selection < model.rows.count
        else { return }
        choose(model.rows[model.selection])
    }

    // MARK: - Jumping

    /// Hides the panel, then jumps to the chosen Space.
    ///
    /// The panel goes away first so its fade does not overlap the Space
    /// transition, which would look like two competing animations.
    private func choose(_ row: HUDViewModel.Row) {
        guard model.fatalMessage == nil else { return }
        dismiss(restoringFocus: false)

        engine.switchTo(space: row.space, in: model.displays) { result in
            if case .failure(let error) = result {
                self.report(error)
            }
        }
    }

    /// Surfaces a switching failure. Only the permission case is actionable, so
    /// that one gets an alert; the rest are logged.
    private func report(_ error: SpaceSwitchEngine.SwitchError) {
        switch error {
        case .automationDenied:
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "alert.automation.title", comment: "Title of the missing-Automation alert")
            alert.informativeText = NSLocalizedString(
                "alert.automation.body", comment: "Body of the missing-Automation alert")
            alert.addButton(withTitle: NSLocalizedString(
                "alert.openSettings", comment: "Button opening System Settings"))
            alert.addButton(withTitle: NSLocalizedString(
                "alert.cancel", comment: "Dismiss button"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                NSWorkspace.shared.open(url)
            }
        case .appleEventFailed(let status):
            NSLog("spaceSwitcher: the Apple Event driving System Events failed (\(status))")
        case .spaceNotFound:
            NSLog("spaceSwitcher: the target Space disappeared before the jump")
        case .didNotArrive(let expected, let actual):
            NSLog("spaceSwitcher: jump did not land — expected \(expected), got \(actual)")
        }
    } // End of report(_:)
}
