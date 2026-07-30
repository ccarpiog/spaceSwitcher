import AppKit
import Carbon.HIToolbox
import Combine

/// Owns the app's global shortcut: which combination is in force, whether Carbon
/// accepted it, and what the settings UI should say when it did not.
///
/// The policy lives here rather than in `GlobalHotKey` because this is the only
/// part that knows what was working a moment ago. A refused shortcut has to leave
/// the previous one running: an app whose way in *is* a shortcut cannot afford to
/// be left with none, least of all while the user is in the middle of changing it.
///
/// The stored preference follows the registration, never the other way round —
/// nothing is written until Carbon has agreed to it, so what is persisted is
/// always something that actually works.
///
/// Recording lives here too, monitor included. It used to belong to the recorder
/// view, which gave every instance of that view its own monitor while the
/// transition it guards is process-wide: two views, two monitors, one of them
/// swallowing key presses after the other had already put the shortcut back.
@MainActor
final class HotKeyController: ObservableObject {

    /// The instance the app runs on.
    static let shared = HotKeyController(preferences: .shared)

    /// Why the last attempt to set a shortcut did not take.
    enum Failure {

        /// The user pressed a key with no ⌘⌃⌥⇧.
        case missingModifier

        /// Carbon refused `attempted`. `kept` is the shortcut still in force —
        /// there always is one, since the replacement is claimed before the old
        /// registration is released.
        case rejected(attempted: HotKeyCombination, kept: HotKeyCombination)

        /// The stored shortcut was refused at launch, so `fallback` stands in for
        /// it. The store still holds `stored`: whatever stopped it may be gone
        /// tomorrow, and overwriting the user's choice behind their back would
        /// make that recovery impossible.
        case usingFallback(stored: HotKeyCombination, fallback: HotKeyCombination)

        /// Nothing at all could be claimed. The menu bar icon is forced on for
        /// this session so the app remains reachable.
        case noShortcut(attempted: HotKeyCombination)

        /// Carbon would not release the shortcut in force, so it cannot be
        /// replaced or re-recorded for now. It does still work.
        case notReleased(HotKeyCombination)

        /// The keyboard could not be read, so recording never started.
        case recorderUnavailable

        /// The Carbon handler is not installed, so no shortcut can work at all.
        case dispatchUnavailable

        /// The message shown under the recorder.
        var message: String {
            switch self {
            case .missingModifier:
                return NSLocalizedString(
                    "settings.general.hotKey.error.noModifier",
                    comment: "Shown when the recorded shortcut has no modifier key")
            case .rejected(let attempted, let kept):
                return String(format: NSLocalizedString(
                    "settings.general.hotKey.error.taken",
                    comment: "Shown when a new shortcut was refused; %1$@ is the "
                        + "refused combination, %2$@ the one still in use"),
                              attempted.displayString, kept.displayString)
            case .usingFallback(let stored, let fallback):
                return String(format: NSLocalizedString(
                    "settings.general.hotKey.error.usingFallback",
                    comment: "Shown when the stored shortcut was refused at launch; "
                        + "%1$@ is that shortcut, %2$@ the one standing in for it"),
                              stored.displayString, fallback.displayString)
            case .noShortcut(let attempted):
                return String(format: NSLocalizedString(
                    "settings.general.hotKey.error.unavailable",
                    comment: "Shown when nothing could be registered and the menu "
                        + "bar icon was turned on instead; %1$@ is the refused "
                        + "combination"),
                              attempted.displayString)
            case .notReleased(let combination):
                return String(format: NSLocalizedString(
                    "settings.general.hotKey.error.notReleased",
                    comment: "Shown when macOS would not release the current "
                        + "shortcut; %1$@ is that combination"),
                              combination.displayString)
            case .recorderUnavailable:
                return NSLocalizedString(
                    "settings.general.hotKey.error.recorderUnavailable",
                    comment: "Shown when the keyboard could not be read for recording")
            case .dispatchUnavailable:
                return NSLocalizedString(
                    "settings.general.hotKey.error.dispatchUnavailable",
                    comment: "Shown when the app's keyboard handler could not be installed")
            }
        } // End of message
    } // End of enum Failure

    /// Called on the main queue each time the shortcut fires.
    var onPress: (() -> Void)? {
        get { hotKey.onPress }
        set { hotKey.onPress = newValue }
    }

    /// Called when the app has been left with no shortcut at all — which, for an
    /// app whose entire interface is a shortcut, means no way in.
    ///
    /// Wired to the menu bar icon: forcing it on for the session is what keeps
    /// Settings reachable. It is an in-session override rather than a write to the
    /// preference, so the user's own choice is still there once the shortcut is.
    var onUnreachable: (() -> Void)?

    /// Why the last change did not take, or `nil` when the shortcut is fine.
    @Published private(set) var failure: Failure?

    /// Whether the recorder is capturing. While it is, the shortcut is stood down
    /// so the user can press it without the panel jumping in front of them.
    @Published private(set) var isRecording = false

    /// The combination Carbon is dispatching right now, or `nil` when none is.
    ///
    /// Not the same thing as `Preferences.hotKey`, and the difference is the point:
    /// after a launch fallback the store holds the shortcut the user chose while
    /// this holds the one that actually opens the panel. The UI shows this one.
    @Published private(set) var activeCombination: HotKeyCombination?

    private let hotKey = GlobalHotKey()
    private let preferences: Preferences

    /// The monitor swallowing key presses while recording.
    private var monitor: Any?

    /// What was in force when recording started, put back if the user gives up.
    /// Read from the registration rather than from the store, which after a launch
    /// fallback holds a combination that is known not to work.
    private var combinationBeforeRecording: HotKeyCombination?

    /// - Parameter preferences: the store holding the shortcut. Passed in rather
    ///   than defaulted to `.shared`: a default argument is evaluated in a
    ///   nonisolated context, which cannot touch a main-actor-isolated `static let`.
    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Registration

    /// Registers the stored shortcut. Called once the app has finished launching.
    ///
    /// Failing here is not like failing later: there is no Settings window open to
    /// report it in, and no way to open one. The app is `.accessory`, so it has no
    /// dock icon; the menu bar icon is off by default; and `⌘,` only reaches a
    /// window that is already up. A stored shortcut Carbon will not accept would
    /// therefore launch an app with no interface at all. Hence the ladder: the
    /// user's shortcut, then the default, then the menu bar icon.
    func start() {
        let stored = preferences.hotKey
        if adopt(stored, persisting: false) { return }
        let firstFailure = failure

        // Nothing is persisted here. The combination the user chose stays in the
        // store so it can be claimed again on the next launch, once whatever took
        // it is no longer running.
        if stored != .default, adopt(.default, persisting: false) {
            failure = .usingFallback(stored: stored, fallback: .default)
            return
        }

        // Out of shortcuts. Say so in terms of the combination the user actually
        // chose — the fallback is an implementation detail to them — and make the
        // app reachable by other means.
        if case .dispatchUnavailable? = firstFailure {
            failure = .dispatchUnavailable
        } else {
            failure = .noShortcut(attempted: stored)
        }
        ensureReachable()
    } // End of start()

    /// Adopts `combination` as the shortcut, storing it only once Carbon has
    /// accepted it.
    ///
    /// - Parameter combination: the shortcut the user chose.
    func apply(_ combination: HotKeyCombination) {
        adopt(combination, persisting: true)
        ensureReachable()
    }

    /// Makes the app reachable by other means when it has ended up with no
    /// shortcut at all.
    ///
    /// Checked after every attempt rather than only at launch: the gap where a
    /// shortcut is genuinely unregistered — the user is recording a new one — is
    /// also a gap in which another app can claim the old combination, and coming
    /// out of it with nothing leaves exactly the same unreachable app.
    private func ensureReachable() {
        guard activeCombination == nil else { return }
        onUnreachable?()
    }

    /// Puts the factory shortcut back.
    func restoreDefault() {
        apply(.default)
    }

    /// Claims `combination` and reports what happened.
    ///
    /// - Parameters:
    ///   - combination: the shortcut to claim.
    ///   - persisting: whether success should be written to the store. `false`
    ///     when the combination is not the user's choice but a stand-in for it —
    ///     a launch fallback, or putting back what an abandoned recording had
    ///     stood down.
    ///   - fallback: what to claim if `combination` is refused *and* nothing is
    ///     registered. Needed for one case only: while recording there is
    ///     genuinely no registration to keep, because the shortcut has to be off
    ///     for the user to be able to press it. Everywhere else `register(_:)`
    ///     holds on to the previous claim itself.
    /// - Returns: whether Carbon accepted `combination`.
    @discardableResult
    private func adopt(_ combination: HotKeyCombination,
                       persisting: Bool,
                       fallback: HotKeyCombination? = nil) -> Bool {
        do {
            try hotKey.register(combination)
            if persisting { preferences.hotKey = combination }
            activeCombination = hotKey.combination
            failure = nil
            return true
        } catch {
            // `register` leaves the previous registration untouched when it fails,
            // so what the hotkey reports afterwards is exactly what is still in
            // force — no guesswork, and nothing to put back except in the
            // recording case the caller passes a fallback for.
            if hotKey.combination == nil, let fallback {
                try? hotKey.register(fallback)
            }
            activeCombination = hotKey.combination
            failure = HotKeyController.failure(for: error,
                                               attempted: combination,
                                               kept: hotKey.combination)
            return false
        }
    } // End of adopt(_:persisting:fallback:)

    /// Turns what `GlobalHotKey` threw into what the user should be told.
    ///
    /// - Parameters:
    ///   - error: the thrown error.
    ///   - attempted: the combination that was refused.
    ///   - kept: the combination left in force, if any.
    private static func failure(for error: Error,
                                attempted: HotKeyCombination,
                                kept: HotKeyCombination?) -> Failure {
        guard let registration = error as? GlobalHotKey.RegistrationError else {
            return kept.map { .rejected(attempted: attempted, kept: $0) }
                ?? .noShortcut(attempted: attempted)
        }

        switch registration {
        case .missingModifier:
            return .missingModifier
        case .handlerUnavailable:
            return .dispatchUnavailable
        case .releaseFailed:
            // The shortcut that would not go is the one still working.
            return .notReleased(kept ?? attempted)
        case .rejected:
            return kept.map { .rejected(attempted: attempted, kept: $0) }
                ?? .noShortcut(attempted: attempted)
        }
    } // End of failure(for:attempted:kept:)

    // MARK: - Recording

    /// Stands the shortcut down and starts reading the keyboard.
    ///
    /// The monitor goes in before the shortcut comes off, and the whole thing is
    /// abandoned if either half fails. The other order strands the app: the
    /// shortcut released, no monitor to record a new one with, and a recorder
    /// stuck in a state nothing can end.
    func startCapturing() {
        guard !isRecording else { return }

        let inForce = activeCombination ?? preferences.hotKey
        guard let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                self?.capture(event)
                // Swallowed whatever it was. Anything let through here would be
                // typed into whichever control is focused behind the recorder.
                return nil
            })
        else {
            failure = .recorderUnavailable
            return
        }

        do {
            try hotKey.unregister()
        } catch {
            NSEvent.removeMonitor(monitor)
            failure = HotKeyController.failure(for: error,
                                               attempted: inForce,
                                               kept: hotKey.combination)
            return
        }

        self.monitor = monitor
        combinationBeforeRecording = inForce
        activeCombination = nil
        isRecording = true
        failure = nil
    } // End of startCapturing()

    /// Ends capture without changing the shortcut, putting back whatever was
    /// stood down. Safe to call when nothing is being recorded, which is what
    /// makes it usable from every teardown path — the button, the view going
    /// away, the window closing, the app losing focus.
    func stopCapturing() {
        endRecording(with: nil)
    }

    /// Turns one intercepted key press into the new shortcut, or gives up on
    /// Escape.
    ///
    /// - Parameter event: the press the monitor swallowed.
    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)

        // Escape on its own means "forget it". Held with a modifier it is an
        // ordinary combination, so `⌃⎋` can still be recorded.
        if Int(event.keyCode) == kVK_Escape && flags.isEmpty {
            stopCapturing()
            return
        }

        endRecording(with: HotKeyCombination(keyCode: UInt32(event.keyCode),
                                             flags: flags))
    } // End of capture(_:)

    /// Ends capture and registers whatever should be in force afterwards.
    ///
    /// - Parameter combination: what the user pressed, or `nil` if they gave up,
    ///   in which case the shortcut that was stood down goes straight back on —
    ///   and is not written to the store, since giving up changed nothing.
    private func endRecording(with combination: HotKeyCombination?) {
        guard isRecording else { return }

        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false

        let restored = combinationBeforeRecording ?? preferences.hotKey
        combinationBeforeRecording = nil

        if let combination {
            adopt(combination, persisting: true, fallback: restored)
        } else {
            adopt(restored, persisting: false)
        }
        ensureReachable()
    } // End of endRecording(with:)
}
