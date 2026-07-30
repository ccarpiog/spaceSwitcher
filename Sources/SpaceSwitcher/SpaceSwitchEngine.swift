import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Performs the actual jump between Spaces.
///
/// The mechanism is deliberately indirect, because the direct routes do not
/// work — see CLAUDE.md. In short:
///
/// - `CGSManagedDisplaySetCurrentSpace` desyncs the compositor and must not be used.
/// - Synthesised `CGEvent` key presses never reach the WindowServer hotkey matcher.
/// - Driving `Ctrl+←`/`Ctrl+→` through System Events works, so that is what this does.
///
/// Because navigation is relative, the engine computes how many steps separate
/// the current Space from the target within its display's ordering, then walks
/// that far and confirms arrival by polling `CGSGetActiveSpace`.
final class SpaceSwitchEngine {

    /// Why a switch could not be completed.
    enum SwitchError: Error {
        /// The user explicitly refused Automation access to System Events.
        case automationDenied
        /// The Apple Event failed for some reason other than a refusal.
        case appleEventFailed(status: OSStatus)
        /// The Space vanished between enumeration and the switch.
        case spaceNotFound
        /// The keypresses were sent but the Space never became active.
        case didNotArrive(expected: UInt64, actual: UInt64)
        /// The user moved on before the walk finished, so it stopped where it was.
        case cancelled
    }

    /// A one-way "stop" signal for a jump that has already been handed over.
    ///
    /// The controller decides a jump is stale on the main actor, but the walk runs
    /// on this class's own serial queue, so the two cannot share the controller's
    /// `pendingJump`: that is main-actor confined and identity comparison is not
    /// something a background queue may do with it. This object is the one piece of
    /// a jump both sides are allowed to touch, so it carries its own lock.
    ///
    /// One-way on purpose. A cancelled jump is never revived; the controller
    /// allocates a fresh one per selection, exactly as it does the jump itself.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        /// Whether the jump has been given up on. Safe to ask from any thread.
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        /// Gives up on the jump. Safe to call from any thread, and idempotent.
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private let bridge: SkyLightBridge
    /// Apple Events are dispatched off the main thread so the panel's fade-out
    /// animation is not blocked by the Space transition.
    private let queue = DispatchQueue(label: "cc.carpio.spaceSwitcher.switching")

    private static let leftArrowKeyCode = 123
    private static let rightArrowKeyCode = 124
    /// Upper bound on how long to wait for one Space transition to complete.
    /// The animation measured ~0.75 s on macOS 27; this leaves generous headroom.
    private static let arrivalTimeout: TimeInterval = 2.5
    private static let pollInterval: TimeInterval = 0.05

    init(bridge: SkyLightBridge = .shared) {
        self.bridge = bridge
    }

    // MARK: - Permission

    /// Where the user stands on letting this app drive System Events.
    ///
    /// The middle case matters: an app that has never sent an Apple Event is not
    /// denied, it simply has not asked yet. Collapsing the two into a boolean
    /// makes a first launch look refused.
    enum AutomationStatus {
        /// Allowed — jumping will work.
        case granted
        /// Never requested. The prompt appears on the first jump; nothing to warn about.
        case notDetermined
        /// Actively refused, or blocked. Jumping cannot work until this changes.
        case denied
    }

    /// `AEDeterminePermissionToAutomateTarget` returns this when consent has not
    /// been sought yet. Spelled out because the symbol is not surfaced to Swift.
    private static let errWouldRequireConsent: OSStatus = -1744
    /// Returned when the target app is not running. System Events is a faceless
    /// background app that is usually *not* running, so this is the common case —
    /// and it says nothing whatsoever about permission.
    private static let errProcNotFound: OSStatus = -600
    /// The only code that actually means the user refused.
    static let errEventNotPermitted: OSStatus = -1743

    /// Checks whether System Events automation is permitted.
    ///
    /// - Parameter prompting: `false` to look without triggering a TCC prompt, so
    ///   the panel can decide what to show. `true` when a jump is actually being
    ///   attempted and the prompt is expected.
    func automationStatus(prompting: Bool = false) -> AutomationStatus {
        var target = AEAddressDesc()
        // `AECreateDesc` returns OSErr (Int16), not OSStatus (Int32), so it is
        // compared against a literal rather than `noErr`.
        let bundleID = Array("com.apple.systemevents".utf8)
        let created = AECreateDesc(typeApplicationBundleID,
                                   bundleID,
                                   bundleID.count,
                                   &target)
        guard created == 0 else { return .denied }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, prompting)
        switch status {
        case noErr:
            return .granted
        case SpaceSwitchEngine.errEventNotPermitted:
            return .denied
        case SpaceSwitchEngine.errWouldRequireConsent,
             SpaceSwitchEngine.errProcNotFound:
            return .notDetermined
        default:
            // Anything else is inconclusive. Treated as "not asked yet" rather than
            // as a refusal: warning the user about a permission they have not
            // actually been denied is worse than staying quiet, since the real
            // prompt appears on the first jump anyway.
            NSLog("spaceSwitcher: inconclusive automation status \(status); assuming not yet requested")
            return .notDetermined
        }
    } // End of automationStatus(prompting:)

    // MARK: - Switching

    /// Jumps to `space`, reporting the outcome on the main queue.
    ///
    /// The work is queued rather than done here, which is what `cancellation` is
    /// for: by the time the first keypress goes out the user may already have
    /// reopened the panel or opened Settings, and a walk several Spaces long can
    /// still be running when they do. The signal is therefore asked before *every*
    /// press, not once at the start, and a walk that is told to stop stops where it
    /// has got to — see `SwitcherController.abandonPendingJump(because:)` for why
    /// stopping beats retracing.
    ///
    /// - Parameters:
    ///   - space: the Space to land on.
    ///   - displays: the enumeration the target came from, used to work out the
    ///     ordering and to locate the display for a cursor warp.
    ///   - cancellation: asked before the cursor warp and before each keypress.
    ///   - completion: called on the main queue with success or the reason for failure.
    func switchTo(space: Space,
                  in displays: [DisplaySpaces],
                  cancellation: Cancellation,
                  completion: @escaping (Result<Void, SwitchError>) -> Void) {

        guard let display = displays.first(where: { $0.id == space.displayID }),
              let targetIndex = display.spaces.firstIndex(where: { $0.id == space.id })
        else {
            DispatchQueue.main.async { completion(.failure(.spaceNotFound)) }
            return
        }

        // Already there — nothing to do, and sending zero keypresses would
        // otherwise report a spurious failure.
        if bridge.activeSpaceID() == space.id {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }

            // The queue is serial, so this may have waited behind an earlier walk,
            // and the user may have moved on in the meantime. Asked before the
            // cursor warp below, which is both visible and 50 ms long — the widest
            // part of the window between the choice and the first keypress.
            if cancellation.isCancelled {
                DispatchQueue.main.async { completion(.failure(.cancelled)) }
                return
            }

            // No permission pre-check here. Sending the event is itself the check:
            // it launches System Events if needed and raises the TCC prompt at a
            // moment the user understands. Pre-checking would report a refusal
            // whenever System Events merely happened not to be running.

            // With "Displays have separate Spaces" on, relative navigation acts
            // on whichever display has focus. Warping the cursor onto the target
            // display makes it the one that moves.
            self.focusDisplayIfNeeded(display)

            // Navigation starts from the Space showing on the *target* display, not
            // from the globally active one. When the target is on another display
            // those differ, and using the global value would look up a Space that
            // is not in this display's list at all, aborting the jump.
            //
            // Read now rather than taken from `displays`: that snapshot says where
            // the display was when the user was looking at the panel, and the walk
            // has to start from where it is once the cursor has been warped onto
            // it. The two differ whenever anything moved in between — the user
            // themselves, or an earlier jump of ours only just finishing — and a
            // delta measured from the wrong end walks the wrong distance. The
            // *ordering* still comes from the snapshot, because that is the list
            // the user picked from.
            let currentID = self.bridge.currentSpace(onDisplay: display.id)
                ?? display.currentSpaceID
            guard let currentIndex = display.spaces
                .firstIndex(where: { $0.id == currentID })
            else {
                DispatchQueue.main.async { completion(.failure(.spaceNotFound)) }
                return
            }

            let delta = targetIndex - currentIndex
            // Nothing to walk: warping the cursor above already moved focus to the
            // target display, and the wanted Space is the one it is showing.
            if delta == 0 {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            let keyCode = delta > 0
                ? SpaceSwitchEngine.rightArrowKeyCode
                : SpaceSwitchEngine.leftArrowKeyCode

            // Walk one Space at a time, waiting for each transition to settle.
            // Stepping blindly would drop presses during the animation.
            for _ in 0..<abs(delta) {
                // Before every press, not merely before the first: a walk of
                // several Spaces takes seconds, and the user can reopen the panel
                // or open Settings halfway through it. Stopping here is safe as
                // well as prompt — the previous step has already settled, so the
                // display is left showing a Space rather than mid-animation.
                if cancellation.isCancelled {
                    DispatchQueue.main.async { completion(.failure(.cancelled)) }
                    return
                }
                let before = self.bridge.currentSpace(onDisplay: display.id)
                    ?? self.bridge.activeSpaceID()
                let error = self.sendControlKey(keyCode)
                if error != 0 {
                    // Only an explicit refusal is reported as such; any other
                    // failure is a genuine error worth surfacing differently.
                    let failure: SwitchError = error == SpaceSwitchEngine.errEventNotPermitted
                        ? .automationDenied
                        : .appleEventFailed(status: error)
                    DispatchQueue.main.async { completion(.failure(failure)) }
                    return
                }
                self.waitForSpaceChange(from: before, onDisplay: display.id)
            } // End of the loop stepping one Space at a time toward the target

            let arrived = self.bridge.currentSpace(onDisplay: display.id)
                ?? self.bridge.activeSpaceID()
            DispatchQueue.main.async {
                if arrived == space.id {
                    completion(.success(()))
                } else {
                    completion(.failure(.didNotArrive(expected: space.id, actual: arrived)))
                }
            }
        } // End of the async block performing the whole switch off the main thread
    } // End of switchTo(space:in:cancellation:completion:)

    // MARK: - Mechanics

    /// Sends one `Ctrl`+arrow press through System Events.
    ///
    /// `NSAppleScript` is used rather than spawning `osascript`, which would add
    /// process-launch latency to every step. A fresh instance per call keeps this
    /// safe on the serial queue it runs on.
    ///
    /// - Returns: `0` on success, otherwise the Apple Event error number. `-1743`
    ///   means the user refused; anything else is some other failure.
    private func sendControlKey(_ keyCode: Int) -> OSStatus {
        let source = "tell application \"System Events\" to key code \(keyCode) using control down"
        guard let script = NSAppleScript(source: source) else { return -1 }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let code = OSStatus(error[NSAppleScript.errorNumber] as? Int ?? -1)
            NSLog("spaceSwitcher: System Events key code failed (\(code)): \(error)")
            return code
        }
        return 0
    } // End of sendControlKey(_:)

    /// Blocks until the Space showing on `displayID` differs from `previous`, or
    /// the timeout expires.
    ///
    /// Polling is legitimate here: the transition is driven by a real Dock-level
    /// switch, so the value reflects something the compositor is actually doing —
    /// unlike the private setter, whose bookkeeping updates mean nothing.
    ///
    /// Deliberately *not* cancellable, unlike the walk that calls it. The press has
    /// already gone to System Events and the Space is moving regardless; returning
    /// early would only report a Space the compositor is in the middle of leaving,
    /// and the next jump computes its distance from exactly that reading. The cost
    /// is that a cancelled walk holds the serial queue until its last step settles,
    /// which is one animation, and which any following jump would have waited for
    /// anyway.
    private func waitForSpaceChange(from previous: UInt64, onDisplay displayID: String) {
        let deadline = Date().addingTimeInterval(SpaceSwitchEngine.arrivalTimeout)
        while Date() < deadline {
            let now = bridge.currentSpace(onDisplay: displayID) ?? bridge.activeSpaceID()
            if now != previous { return }
            Thread.sleep(forTimeInterval: SpaceSwitchEngine.pollInterval)
        }
    } // End of waitForSpaceChange(from:onDisplay:)

    /// Moves the cursor onto `display` when the active Space lives elsewhere.
    ///
    /// Without this, `Ctrl+←`/`Ctrl+→` would move the wrong display's Spaces on a
    /// multi-monitor setup with separate Spaces enabled.
    private func focusDisplayIfNeeded(_ display: DisplaySpaces) {
        let activeID = bridge.activeSpaceID()
        guard !display.spaces.contains(where: { $0.id == activeID }) else { return }
        guard let screen = NSScreenAdapter.screen(forUUID: display.id) else { return }

        // Core Graphics uses a top-left origin, AppKit a bottom-left one, so the
        // y coordinate has to be flipped against the primary screen's height.
        let centre = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let flipped = CGPoint(x: centre.x, y: primaryHeight - centre.y)
        CGWarpMouseCursorPosition(flipped)
        CGAssociateMouseAndMouseCursorPosition(1)
        Thread.sleep(forTimeInterval: 0.05)
    } // End of focusDisplayIfNeeded(_:)
}
