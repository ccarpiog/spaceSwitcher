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
        /// The user has not granted (or has denied) Automation access to System Events.
        case automationDenied
        /// The Space vanished between enumeration and the switch.
        case spaceNotFound
        /// The keypresses were sent but the Space never became active.
        case didNotArrive(expected: UInt64, actual: UInt64)
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

    /// Whether System Events automation is already permitted.
    ///
    /// Uses `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`
    /// so the panel can show its status without triggering a TCC prompt at an
    /// awkward moment.
    func automationPermission(prompting: Bool = false) -> Bool {
        var target = AEAddressDesc()
        // `AECreateDesc` returns OSErr (Int16), not OSStatus (Int32), so it is
        // compared against a literal rather than `noErr`.
        let bundleID = Array("com.apple.systemevents".utf8)
        let created = AECreateDesc(typeApplicationBundleID,
                                   bundleID,
                                   bundleID.count,
                                   &target)
        guard created == 0 else { return false }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, prompting)
        return status == noErr
    } // End of automationPermission(prompting:)

    // MARK: - Switching

    /// Jumps to `space`, reporting the outcome on the main queue.
    ///
    /// - Parameters:
    ///   - space: the Space to land on.
    ///   - displays: the enumeration the target came from, used to work out the
    ///     ordering and to locate the display for a cursor warp.
    ///   - completion: called on the main queue with success or the reason for failure.
    func switchTo(space: Space,
                  in displays: [DisplaySpaces],
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

            guard self.automationPermission(prompting: true) else {
                DispatchQueue.main.async { completion(.failure(.automationDenied)) }
                return
            }

            // With "Displays have separate Spaces" on, relative navigation acts
            // on whichever display has focus. Warping the cursor onto the target
            // display makes it the one that moves.
            self.focusDisplayIfNeeded(display)

            // The starting index has to be read *after* the warp, because the
            // active Space is now the one on the target display.
            let currentID = self.bridge.activeSpaceID()
            guard let currentIndex = display.spaces.firstIndex(where: { $0.id == currentID })
            else {
                DispatchQueue.main.async { completion(.failure(.spaceNotFound)) }
                return
            }

            let delta = targetIndex - currentIndex
            let keyCode = delta > 0
                ? SpaceSwitchEngine.rightArrowKeyCode
                : SpaceSwitchEngine.leftArrowKeyCode

            // Walk one Space at a time, waiting for each transition to settle.
            // Stepping blindly would drop presses during the animation.
            for _ in 0..<abs(delta) {
                let before = self.bridge.activeSpaceID()
                guard self.sendControlKey(keyCode) else {
                    DispatchQueue.main.async { completion(.failure(.automationDenied)) }
                    return
                }
                self.waitForSpaceChange(from: before)
            } // End of the loop stepping one Space at a time toward the target

            let arrived = self.bridge.activeSpaceID()
            DispatchQueue.main.async {
                if arrived == space.id {
                    completion(.success(()))
                } else {
                    completion(.failure(.didNotArrive(expected: space.id, actual: arrived)))
                }
            }
        } // End of the async block performing the whole switch off the main thread
    } // End of switchTo(space:in:completion:)

    // MARK: - Mechanics

    /// Sends one `Ctrl`+arrow press through System Events.
    ///
    /// `NSAppleScript` is used rather than spawning `osascript`, which would add
    /// process-launch latency to every step. A fresh instance per call keeps this
    /// safe on the serial queue it runs on.
    ///
    /// - Returns: `false` when the Apple Event was refused, which in practice
    ///   means Automation permission is missing.
    private func sendControlKey(_ keyCode: Int) -> Bool {
        let source = "tell application \"System Events\" to key code \(keyCode) using control down"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            NSLog("spaceSwitcher: System Events key code failed (\(code)): \(error)")
            return false
        }
        return true
    } // End of sendControlKey(_:)

    /// Blocks until the active Space differs from `from`, or the timeout expires.
    ///
    /// Polling `CGSGetActiveSpace` is legitimate here: the transition is being
    /// driven by a real Dock-level switch, so the value reflects something the
    /// compositor is actually doing.
    private func waitForSpaceChange(from previous: UInt64) {
        let deadline = Date().addingTimeInterval(SpaceSwitchEngine.arrivalTimeout)
        while Date() < deadline {
            if bridge.activeSpaceID() != previous { return }
            Thread.sleep(forTimeInterval: SpaceSwitchEngine.pollInterval)
        }
    }

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
