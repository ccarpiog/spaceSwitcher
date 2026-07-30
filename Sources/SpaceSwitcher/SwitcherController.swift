import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the hotkey, the panel and the switching engine, and wires them together.
@MainActor
final class SwitcherController {

    private let enumerator = SpaceEnumerator()
    private let engine = SpaceSwitchEngine()
    private let model = HUDViewModel()
    private let preferences = Preferences.shared
    private let menuBar = MenuBarController(preferences: .shared)
    private let hotKeys = HotKeyController.shared

    private var panel: HUDPanel?
    private var keyMonitor: Any?
    /// The app that was frontmost before the panel opened, restored on cancel so
    /// dismissing the HUD leaves the session exactly as it was.
    private var previousApp: NSRunningApplication?

    /// One selection the user has made and is still waiting on.
    ///
    /// A reference type on purpose: identity is the whole point. A jump runs across
    /// two asynchronous hops — waiting for the panel to leave the screen, then the
    /// switch itself — and each hop has to be able to ask "is this still the jump
    /// the user is waiting for?". Comparing against the object it started with
    /// answers that; nothing else does, because the panel is reused and so is its
    /// window number.
    ///
    /// It also carries what the jump acts on, rather than leaving it to be re-read
    /// later: the target Space *and* the layout it was resolved against, both taken
    /// when the user chose. `model.displays` is replaced on every opening, so
    /// resolving against it afterwards would resolve against a list the user never
    /// saw — a different ordering, or no matching Space at all.
    /// It carries a cancellation token besides, because identity alone stops only
    /// what has not left the main actor yet. The engine's walk runs on a background
    /// queue and cannot look at `pendingJump` at all — that is main-actor confined —
    /// so the one thing it can be told is this object, which is safe to read from
    /// any thread. Identity says "do not report"; the token says "do not continue".
    private final class Jump {
        let space: Space
        let displays: [DisplaySpaces]
        let cancellation = SpaceSwitchEngine.Cancellation()

        init(space: Space, displays: [DisplaySpaces]) {
            self.space = space
            self.displays = displays
        }
    }

    /// The jump the user is currently waiting on, or `nil` when they are not
    /// waiting on one. Anything arriving for a different `Jump` is stale and is
    /// dropped rather than acted on.
    private var pendingJump: Jump?

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
        // The status item comes and goes with the preference on its own; all it
        // needs from here is what its entries should do. Started before the
        // shortcut, because it is the fallback when the shortcut cannot be had.
        menuBar.onShowPanel = { [weak self] in self?.present() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.start()

        // The shortcut itself is a setting, so which combination is claimed — and
        // re-claimed whenever the user records a new one — is not this class's
        // business. All it wants is to be told when it fires.
        hotKeys.onPress = { [weak self] in self?.toggle() }
        // An app reached only by a shortcut has to be reachable some other way
        // when there is no shortcut left to reach it by, or it launches invisible
        // and stays that way.
        hotKeys.onUnreachable = { [weak self] in self?.menuBar.forceVisible() }
        hotKeys.start()

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
        // The names are read here, on every opening, rather than held anywhere:
        // the user may have renamed a Space in Settings a second ago, and the
        // panel is the place that has to show it.
        model.displays = enumerator.enumerate(customNames: preferences.spaceNames)
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
        // The panel being back on screen ends any wait the user had walked away
        // from. Two things follow from putting it here rather than in `dismiss`:
        // the panel reopened over an unfinished jump no longer lets that jump fire
        // underneath it, and a failure from it no longer yanks the HUD back once
        // the user has moved on.
        abandonPendingJump(because: "the panel was opened again")

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
    /// - Returns: the window number the window server has been asked to stop
    ///   compositing, or `0` if there was no panel. Callers whose next step must
    ///   not overlap the panel hand it to `HUDPanel.whenOffScreen(windowNumber:then:)`.
    @discardableResult
    private func dismiss(restoringFocus: Bool) -> Int {
        removeKeyMonitor()
        let hidden = panel?.hideNow() ?? 0
        if restoringFocus, let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
        return hidden
    } // End of dismiss(restoringFocus:)

    /// Gives up on whatever the user was waiting for: nothing that arrives for it
    /// afterwards is acted on, and if it has already started it stops.
    ///
    /// Both halves are needed, because a jump spans two worlds. Clearing
    /// `pendingJump` invalidates the identity every main-actor hop compares against,
    /// so a jump that has not started is not started and a failure from a moment the
    /// user has left behind is logged rather than shown. Cancelling the token
    /// reaches the walk itself, which by then is running on the engine's own queue
    /// where `pendingJump` is out of reach; the engine asks the token before every
    /// keypress.
    ///
    /// **A stopped walk stays where it stopped.** The press already handed to System
    /// Events cannot be recalled, so a multi-Space walk halts on the next Space
    /// boundary — possibly short of the target. Retracing was the alternative and is
    /// wrong twice over: the reason for stopping is that a window is now on screen,
    /// so every extra transition is precisely the panel-drawn-over-a-transition
    /// defect this exists to prevent, and walking back doubles them instead of
    /// avoiding them. Nor is the user left anywhere the app cannot describe:
    /// `present()` re-enumerates and re-selects on every opening, so the panel they
    /// just opened lists the Spaces from wherever the walk stopped, with the
    /// selection placed relative to it. One more keystroke finishes the journey.
    ///
    /// - Parameter reason: what the user did, for the log.
    private func abandonPendingJump(because reason: String) {
        guard let jump = pendingJump else { return }
        pendingJump = nil
        jump.cancellation.cancel()
        NSLog("spaceSwitcher: dropping the jump still in hand because \(reason)")
    } // End of abandonPendingJump(because:)

    // MARK: - Settings

    /// Opens the Settings window, closing the panel on the way if it is up.
    ///
    /// Focus is deliberately not restored to the previous app: it is about to go to
    /// the Settings window instead, and handing it back first would raise the other
    /// app over the window that was just asked for.
    ///
    /// Reachable from the menu bar with no panel on screen, which is why it drops a
    /// pending jump itself instead of relying on `showPanel()` to have done it: a
    /// failure surfacing after Settings has opened would pull the HUD in front of
    /// the window the user just asked for.
    private func openSettings() {
        abandonPendingJump(because: "Settings was opened")
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

    /// Hides the panel, waits for it to actually be off screen, then jumps.
    ///
    /// The wait is not ceremony. The panel joins every Space, so anything still
    /// being composited when the transition starts is carried through it in full
    /// view — which is exactly what the user saw. `orderOut` only *asks* the window
    /// server to remove the window, so what the jump has to wait for is the removal
    /// having happened, not the call having returned.
    ///
    /// Everything the jump needs is taken here, while the user is looking at it,
    /// and travels in a `Jump` whose identity says whether it is still wanted. Both
    /// halves matter: the target and its layout must be the ones on screen when the
    /// choice was made, and the completion must be able to tell that the user has
    /// since reopened the panel — in which case firing the jump would put the very
    /// transition-under-an-open-panel back that all of this exists to prevent.
    ///
    /// Identity answers that question only where it can be asked, which is on the
    /// main actor: after the removal wait, and again when the engine reports back.
    /// In between the walk is on the engine's queue, out of reach of `pendingJump`
    /// and free to run for seconds. The same `Jump` therefore carries a cancellation
    /// token, handed to the engine and asked by it before every keypress, so a walk
    /// the user has moved on from stops instead of finishing underneath them.
    ///
    /// Failures are still reported after the panel is gone. Reinstating the panel
    /// to carry the bad news would put it back on screen halfway through whatever
    /// the transition did manage to do; the permission case — the only one the user
    /// can act on — gets an alert instead, and the panel is one keystroke away.
    private func choose(_ row: HUDViewModel.Row) {
        guard model.fatalMessage == nil else { return }

        // A second choice does not merely overwrite the first: whatever the first
        // one already set in motion has to be stopped, and only the old object can
        // do that. In practice the panel has to be reopened to choose again, and
        // `showPanel()` has already done this — but the guarantee belongs here, with
        // the replacement, not with the route that happens to lead to it.
        abandonPendingJump(because: "another Space was chosen")
        let jump = Jump(space: row.space, displays: model.displays)
        pendingJump = jump
        let hidden = dismiss(restoringFocus: false)

        HUDPanel.whenOffScreen(windowNumber: hidden) { [weak self] removal in
            guard let self else { return }
            // Stale by now: the user reopened the panel, opened Settings, or chose
            // again. The window number alone could not have told us — the panel is
            // reused, so a reopened one carries the same number the wait watched.
            guard self.pendingJump === jump else {
                NSLog("spaceSwitcher: the panel is back up; not jumping to Space "
                      + "\(jump.space.id) any more")
                return
            }
            // Expiry is not silent. The jump goes ahead — a hotkey that does
            // nothing is worse than a panel drawn over a transition — but the
            // guarantee did not hold, and that has to be findable afterwards.
            if case .timedOut(let waited) = removal {
                NSLog("spaceSwitcher: the panel was still on screen after "
                      + String(format: "%.0f ms", waited * 1000)
                      + "; jumping to Space \(jump.space.id) anyway, possibly over it")
            }
            self.engine.switchTo(space: jump.space,
                                 in: jump.displays,
                                 cancellation: jump.cancellation) { result in
                guard self.pendingJump === jump else {
                    NSLog("spaceSwitcher: ignoring the outcome of a jump the user "
                          + "has moved on from (\(result))")
                    return
                }
                self.pendingJump = nil
                if case .failure(let error) = result {
                    self.report(error)
                }
            }
        }
    } // End of choose(_:)

    /// Surfaces a switching failure.
    ///
    /// Every failure has to say something now. The panel is taken off screen
    /// *before* the jump starts, so a silent failure leaves the user with no panel,
    /// no Space change and no idea why — the one outcome that reads as the app
    /// being broken. The permission case is the only actionable one and keeps its
    /// alert, with the button into System Settings; the rest bring the panel back
    /// with a note, which is both the explanation and the way to try again.
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
            reopenWithFailureNotice()
        case .spaceNotFound:
            NSLog("spaceSwitcher: the target Space disappeared before the jump")
            reopenWithFailureNotice()
        case .didNotArrive(let expected, let actual):
            NSLog("spaceSwitcher: jump did not land — expected \(expected), got \(actual)")
            reopenWithFailureNotice()
        case .cancelled:
            // Not reachable in practice: cancelling the token and invalidating the
            // identity are the same act, so this outcome is dropped by the guard
            // above before it ever gets here. Handled anyway, and silently — the
            // walk stopped because the user asked for something else and is looking
            // at it now, so there is nothing to tell them and nothing to reopen.
            NSLog("spaceSwitcher: a jump stopped because the user had moved on")
        }
    } // End of report(_:)

    /// Brings the panel back up with a note saying the jump did not go through.
    ///
    /// `present()` re-reads the Spaces on the way, so what comes back is the layout
    /// as it is now — which matters after `spaceNotFound` and `didNotArrive`, where
    /// the list the failed jump was computed from is exactly the thing that turned
    /// out to be wrong. The note is set afterwards because `present()` decides the
    /// notice itself, and this one supersedes it: it describes something that just
    /// happened rather than something that might.
    private func reopenWithFailureNotice() {
        present()
        model.notice = NSLocalizedString(
            "error.jumpFailed",
            comment: "Shown above the list when a jump failed for a reason other than permission")
    }
}
