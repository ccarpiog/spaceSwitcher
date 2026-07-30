import AppKit
import SwiftUI

/// A borderless floating panel that can take key events without activating the
/// app in the usual sense.
///
/// `.nonactivatingPanel` plus `canBecomeKey` lets the panel own the keyboard
/// while it is up, and `.canJoinAllSpaces` is essential: a window that exists on
/// every Space stops macOS from yanking the active Space back to wherever this
/// app "lives" once the switch happens.
///
/// That flag is also why the panel has to be taken off screen *before* a Space
/// transition rather than during it: a window on every Space is drawn on the
/// incoming one too, so a panel that outlives the start of the switch is carried
/// through the animation in full view. Hence `hideNow()` and
/// `whenOffScreen(windowNumber:then:)`.
final class HUDPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called when the user dismisses the panel with Escape or by clicking away.
    var onCancel: (() -> Void)?

    /// The animation the panel is *shown* with. Kept as a constant because
    /// `hideNow()` turns it off for the duration of one call and has to put back
    /// exactly what was there.
    private static let openingAnimation: NSWindow.AnimationBehavior = .utilityWindow

    /// How long to wait for the window server to confirm the panel has left the
    /// screen before going ahead regardless.
    ///
    /// A safety valve, not a cancel. Expiry means the removal could not be
    /// *confirmed*; the user still picked a Space, and a hotkey that silently does
    /// nothing is a worse failure than a panel briefly drawn over a transition. So
    /// the jump proceeds — but the caller is told the guarantee did not hold, and
    /// says so in the log.
    ///
    /// The bound is therefore sized so that reaching it is anomalous rather than
    /// merely unlikely. Measured on this machine over 15 hide cycles, with the
    /// panel hidden through the same path a jump uses: 29.5 ms at best, 39.8 ms
    /// median, 98.3 ms worst — and 149 ms is the worst ever seen here across every
    /// run. One second is about seven times that, which is well past anything load
    /// could plausibly account for. It is not tuned to the median on purpose: the
    /// spread between runs is nearly fivefold, and this bound only has to be too
    /// large to reach.
    private static let offScreenTimeout: TimeInterval = 1.0

    /// Gap between two questions to the window server. Deliberately shorter than a
    /// display refresh, so the polling itself is never what delays the answer.
    private static let offScreenPollInterval: TimeInterval = 0.002

    /// Where the polling happens. Never the main thread: the removal being waited
    /// for is applied when the main run loop turns, so polling there observes the
    /// panel on screen forever — measured, not assumed. `.userInteractive` because
    /// the user is waiting on this: every millisecond the answer is late is a
    /// millisecond added between choosing a Space and going to it.
    private static let offScreenQueue =
        DispatchQueue(label: "cc.carpio.spaceSwitcher.panelRemoval", qos: .userInteractive)

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = HUDPanel.openingAnimation
    } // End of init(contentRect:)

    /// Routes Escape to cancellation; everything else goes to the content view.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // MARK: - Removal

    /// What the wait for the panel's removal actually established.
    ///
    /// The two cases are not interchangeable, which is the reason for spelling them
    /// out rather than just calling back: only one of them means the panel is
    /// certainly gone, and a caller that acts on both has to know which it got.
    enum Removal {
        /// The window server confirmed the panel had stopped being composited,
        /// after this long.
        case confirmed(after: TimeInterval)
        /// The wait expired first, so the panel may still be on screen. The
        /// elapsed time is carried so the caller can report how long it waited.
        case timedOut(after: TimeInterval)
    }

    /// Takes the panel off screen at once, and reports the window number the window
    /// server has been asked to stop compositing.
    ///
    /// `.utilityWindow` fades the panel in *and* out, and the fade-out is why the
    /// panel used to ride through a Space transition: `orderOut` kicks off an
    /// animation that outlives the call, so the window is still being drawn when
    /// the switch begins. The animation is suppressed for this one call and put
    /// back immediately, so opening the panel still fades in — closing it is the
    /// half that has to be instant.
    ///
    /// This is only half the guarantee. The ordering operation still has to reach
    /// the compositor; `whenOffScreen(windowNumber:then:)` is what waits for that.
    ///
    /// - Returns: the window number to wait on, or `0` when there is no window
    ///   device to wait on at all.
    @discardableResult
    func hideNow() -> Int {
        // Read before ordering out: the window device may go with the window.
        let number = windowNumber
        animationBehavior = .none
        orderOut(nil)
        animationBehavior = HUDPanel.openingAnimation
        return number
    } // End of hideNow()

    /// Calls `body` on the main queue once the window server has stopped
    /// compositing the window with `windowNumber`, or once the wait times out,
    /// saying which of the two happened.
    ///
    /// `orderOut` returning is not evidence of anything having left the screen: it
    /// hands an ordering operation to the window server, which applies it on its
    /// own schedule. Anything that must not overlap the panel — the Space
    /// transition above all — has to wait for the window server's own answer.
    ///
    /// **The window number does not identify the panel across a reopening.** The
    /// app keeps one `HUDPanel` and shows it again, so a panel brought back while
    /// this is still waiting carries the very number being watched: the wait then
    /// runs to its bound and reports `.timedOut`, correctly, because the panel is
    /// indeed on screen. Deciding whether the completion is still *wanted* is the
    /// caller's job and cannot be done here — see `SwitcherController.choose(_:)`.
    ///
    /// - Parameters:
    ///   - windowNumber: what `hideNow()` returned.
    ///   - body: run on the main queue with what the wait established.
    static func whenOffScreen(windowNumber: Int, then body: @escaping (Removal) -> Void) {
        // No window device means nothing is being composited, so there is nothing
        // to wait for and no wait to report.
        guard windowNumber > 0 else {
            DispatchQueue.main.async { body(.confirmed(after: 0)) }
            return
        }
        offScreenQueue.async {
            let started = Date()
            let deadline = started.addingTimeInterval(offScreenTimeout)
            var outcome = Removal.confirmed(after: 0)
            while isOnScreen(windowNumber: windowNumber) {
                if Date() >= deadline {
                    outcome = .timedOut(after: Date().timeIntervalSince(started))
                    break
                }
                Thread.sleep(forTimeInterval: offScreenPollInterval)
            } // End of the loop waiting for the window server to drop the panel
            if case .confirmed = outcome {
                outcome = .confirmed(after: Date().timeIntervalSince(started))
            }
            DispatchQueue.main.async { body(outcome) }
        }
    } // End of whenOffScreen(windowNumber:then:)

    /// Whether the window server is currently compositing the window with this number.
    ///
    /// Asked of the on-screen window list rather than of `NSWindow.isVisible`,
    /// which is AppKit's own bookkeeping: it flips the instant `orderOut` is
    /// called, well before anything has left the display.
    ///
    /// - Returns: `false` when the list cannot be read, so an unanswerable question
    ///   never turns into an unbounded wait.
    private static func isOnScreen(windowNumber: Int) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return windows.contains { ($0[kCGWindowNumber as String] as? Int) == windowNumber }
    }

    /// Centres the panel on whichever screen currently holds the mouse, so it
    /// appears where the user is looking on a multi-display setup.
    func centreOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let size = frame.size
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        setFrameOrigin(origin)
    } // End of centreOnActiveScreen()
}
