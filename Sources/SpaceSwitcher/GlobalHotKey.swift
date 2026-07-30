import AppKit
import Carbon.HIToolbox

/// A process-wide hotkey registered with Carbon's `RegisterEventHotKey`.
///
/// Carbon is the only route to a true global hotkey that does not require
/// Accessibility permission and does not need an event tap running. It is
/// long-deprecated but still fully functional, and is what most menu bar
/// utilities use.
///
/// Registration is deliberately separate from the object's lifetime. The shortcut
/// is a setting now, so it has to be swapped while the app runs; this type only
/// claims and releases combinations. What to do when Carbon refuses one belongs
/// to `HotKeyController`, which is the part that knows what was working before.
final class GlobalHotKey {

    /// Why a registration did not happen.
    enum RegistrationError: Error {
        /// The combination carries no ⌘⌃⌥⇧, so it was never attempted.
        case missingModifier
        /// The Carbon handler is not installed, so nothing would dispatch the
        /// shortcut. Registering anyway would claim the combination machine-wide
        /// and then do nothing with it, which looks exactly like a broken app.
        case handlerUnavailable
        /// Carbon refused it. Rarer than it sounds: a combination another process
        /// or the system already holds is accepted, not refused (see `CLAUDE.md`).
        case rejected(OSStatus)
        /// Carbon would not release the combination already in force, so that one
        /// is still registered and still owned here.
        case releaseFailed(OSStatus)
    }

    /// Called on the main queue each time the hotkey fires.
    var onPress: (() -> Void)?

    /// The combination registered right now, or `nil` while none is.
    private(set) var combination: HotKeyCombination?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// The id the live registration was claimed under. It alternates, so a
    /// replacement can be claimed while the current one is still held.
    private var identifier = GlobalHotKey.primaryIdentifier

    /// Identifies our hotkeys inside the shared Carbon event handler.
    private static let signature: OSType = 0x53535743 // 'SSWC'

    /// The two ids registrations alternate between.
    ///
    /// Two rather than one because replacing a shortcut has to be transactional:
    /// the candidate is claimed under whichever id is free while the working
    /// registration is still held, and the old one is released only once the new
    /// one is in hand. With a single id the old reference would be overwritten by
    /// the new registration, so the only safe order would be release-then-claim —
    /// which is precisely the order that loses the shortcut when the claim fails.
    private static let primaryIdentifier: UInt32 = 1
    private static let alternateIdentifier: UInt32 = 2

    /// The id a replacement registration will be claimed under: the one the live
    /// registration is not using.
    private var spareIdentifier: UInt32 {
        identifier == GlobalHotKey.primaryIdentifier
            ? GlobalHotKey.alternateIdentifier
            : GlobalHotKey.primaryIdentifier
    }

    /// Holds an instance without owning it, since a dictionary cannot store a
    /// weak value by itself.
    private struct WeakInstance {
        weak var value: GlobalHotKey?
    }

    /// Every live instance, keyed by hotkey id, so the C callback can find its
    /// owner. Weakly: a strong entry would keep every instance alive for the
    /// life of the process, and `deinit` — the only place the Carbon handler is
    /// removed — would never run.
    private static var instances: [UInt32: WeakInstance] = [:]

    /// Installs the Carbon handler. Nothing is claimed until `register(_:)`.
    init() {
        // Both ids, since a registration moves between them: the callback has to
        // find this instance whichever one the event carries.
        GlobalHotKey.instances[GlobalHotKey.primaryIdentifier] = WeakInstance(value: self)
        GlobalHotKey.instances[GlobalHotKey.alternateIdentifier] = WeakInstance(value: self)
        installHandler()
    }

    /// Makes `combination` the app's global shortcut, releasing whatever was
    /// registered before it.
    ///
    /// The new registration is claimed *first*, under the spare id, and the old
    /// one released only once that has worked. A refusal therefore costs nothing:
    /// the shortcut that was working a moment ago is still registered and still
    /// dispatching, which matters in an app whose only way in is a shortcut.
    ///
    /// - Parameter combination: the shortcut to claim.
    /// - Throws: `RegistrationError`. On failure whatever was registered before
    ///   the call is still registered.
    func register(_ combination: HotKeyCombination) throws {
        guard combination.hasModifier else { throw RegistrationError.missingModifier }

        // Worth one more attempt: a handler that failed to install at launch is
        // the difference between a working app and a dead shortcut.
        installHandler()
        guard handlerRef != nil else { throw RegistrationError.handlerUnavailable }

        // Already ours. Claiming it a second time asks Carbon to register the same
        // combination twice in one process, which it refuses with
        // `eventHotKeyExistsErr` (-9878) — verified, see `CLAUDE.md`. Without this
        // the transaction below would turn a no-op into a failure.
        guard combination != self.combination || hotKeyRef == nil else { return }

        let candidateIdentifier = spareIdentifier
        var candidate: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature,
                                     id: candidateIdentifier)
        let status = RegisterEventHotKey(combination.keyCode,
                                         combination.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &candidate)
        guard status == noErr, let candidate else {
            throw RegistrationError.rejected(status)
        }

        if let hotKeyRef {
            let releaseStatus = UnregisterEventHotKey(hotKeyRef)
            guard releaseStatus == noErr else {
                // The old registration is still live and still ours. Roll the
                // candidate back rather than leave the app holding two claims on
                // the keyboard, and report the one that is actually in force.
                UnregisterEventHotKey(candidate)
                throw RegistrationError.releaseFailed(releaseStatus)
            }
        }

        hotKeyRef = candidate
        identifier = candidateIdentifier
        self.combination = combination
    } // End of register(_:)

    /// Releases the registration, leaving the app without a global shortcut.
    ///
    /// Also the way the shortcut is stood down while the user records a new one:
    /// a registered hotkey is swallowed by the WindowServer before any key event
    /// reaches the app, so the combination most likely to be re-recorded — the
    /// current one — would open the panel instead of being read.
    ///
    /// - Throws: `RegistrationError.releaseFailed` when Carbon refused. The
    ///   reference is kept in that case: it is the only handle capable of
    ///   releasing a registration Carbon still owns, and dropping it would strand
    ///   the combination for the life of the process.
    func unregister() throws {
        guard let hotKeyRef else { return }

        let status = UnregisterEventHotKey(hotKeyRef)
        guard status == noErr else { throw RegistrationError.releaseFailed(status) }

        self.hotKeyRef = nil
        combination = nil
    } // End of unregister()

    /// Installs the single Carbon handler that dispatches to the right instance.
    ///
    /// Its result is read rather than discarded. `RegisterEventHotKey` succeeds
    /// perfectly well with no handler installed, so ignoring a failure here buys a
    /// shortcut that is claimed machine-wide, displayed in Settings as working,
    /// and connected to nothing.
    private func installHandler() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event,
                                               EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID),
                                               nil,
                                               MemoryLayout<EventHotKeyID>.size,
                                               nil,
                                               &hotKeyID)
                // The signature is checked as well as the id. Ids are the caller's
                // to choose, so anything else in this process — a library, a
                // future feature — could register id 1 for its own purposes, and
                // routing on the id alone would fire this app's shortcut for it.
                guard status == noErr,
                      hotKeyID.signature == GlobalHotKey.signature,
                      let instance = GlobalHotKey.instances[hotKeyID.id]?.value
                else { return OSStatus(eventNotHandledErr) }

                DispatchQueue.main.async { instance.onPress?() }
                return noErr
            },
            1,
            &spec,
            nil,
            &installed
        )
        guard status == noErr else { return }

        handlerRef = installed
    } // End of installHandler()

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        // Only clear a slot if it is still ours. The weak reference has already
        // been zeroed by the time this runs, so a non-nil value there means some
        // other instance took the id over — and removing it would cut that one off
        // from the callback.
        for id in [GlobalHotKey.primaryIdentifier, GlobalHotKey.alternateIdentifier]
        where GlobalHotKey.instances[id]?.value == nil {
            GlobalHotKey.instances[id] = nil
        }
    } // End of deinit
}
