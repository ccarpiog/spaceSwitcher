import AppKit
import Carbon.HIToolbox

/// A process-wide hotkey registered with Carbon's `RegisterEventHotKey`.
///
/// Carbon is the only route to a true global hotkey that does not require
/// Accessibility permission and does not need an event tap running. It is
/// long-deprecated but still fully functional, and is what most menu bar
/// utilities use.
final class GlobalHotKey {

    /// Called on the main queue each time the hotkey fires.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Identifies our hotkey inside the shared Carbon event handler.
    private static let signature: OSType = 0x53535743 // 'SSWC'
    private static let identifier: UInt32 = 1

    /// Every live instance, keyed by hotkey id, so the C callback can find its owner.
    private static var instances: [UInt32: GlobalHotKey] = [:]

    /// Registers the hotkey.
    ///
    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_Space`.
    ///   - modifiers: Carbon modifier mask, e.g. `controlKey | optionKey`.
    init(keyCode: UInt32, modifiers: UInt32) {
        GlobalHotKey.instances[GlobalHotKey.identifier] = self
        installHandler()

        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature,
                                     id: GlobalHotKey.identifier)
        let status = RegisterEventHotKey(keyCode,
                                        modifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotKeyRef)
        if status != noErr {
            NSLog("spaceSwitcher: failed to register hotkey (status \(status)) — is it already taken?")
        }
    } // End of init(keyCode:modifiers:)

    /// Installs the single Carbon handler that dispatches to the right instance.
    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
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
                guard status == noErr,
                      let instance = GlobalHotKey.instances[hotKeyID.id]
                else { return OSStatus(eventNotHandledErr) }

                DispatchQueue.main.async { instance.onPress?() }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
    } // End of installHandler()

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        GlobalHotKey.instances[GlobalHotKey.identifier] = nil
    }
}
