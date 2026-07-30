import AppKit
import Carbon.HIToolbox

/// A global shortcut: one key plus the modifiers held with it.
///
/// The modifiers are Carbon's mask (`cmdKey`, `optionKey`, …) rather than
/// `NSEvent.ModifierFlags`. That is what `RegisterEventHotKey` takes and what is
/// persisted, so the Cocoa flags are converted once — where the recorder reads
/// them off an event — instead of being translated back and forth on every use.
struct HotKeyCombination: Equatable {

    /// Virtual key code, e.g. `kVK_Space`.
    let keyCode: UInt32

    /// Carbon modifier mask, e.g. `controlKey | optionKey`.
    let modifiers: UInt32

    /// The shortcut an untouched install uses: `Ctrl+Option+Space`. Chosen to
    /// steer clear of the system's own bindings — `Cmd+Ctrl+Space` is the
    /// Character Viewer and `Ctrl+Space` the input-source switcher.
    static let `default` = HotKeyCombination(keyCode: UInt32(kVK_Space),
                                             modifiers: UInt32(controlKey | optionKey))

    /// Every modifier `RegisterEventHotKey` can match, as one mask.
    private static let allModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    /// - Parameters:
    ///   - keyCode: a virtual key code.
    ///   - modifiers: a Carbon modifier mask.
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a combination from what a key event reports.
    ///
    /// - Parameters:
    ///   - keyCode: the event's virtual key code.
    ///   - flags: the event's modifier flags. Anything Carbon cannot match is
    ///     dropped — Caps Lock in particular, which would otherwise make every
    ///     shortcut recorded with it on impossible to register.
    init(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        self.init(keyCode: keyCode, modifiers: mask)
    }

    /// Whether at least one of ⌘⌃⌥⇧ is part of the combination.
    ///
    /// Worth refusing the rest: Carbon accepts a bare letter and then swallows
    /// that key in every application, with no visible cause and no way back
    /// except reaching these settings — which the shortcut itself is meant to open.
    var hasModifier: Bool { modifiers & HotKeyCombination.allModifiers != 0 }

    /// The combination written the way macOS writes shortcuts, e.g. `⌃⌥␣`.
    ///
    /// The modifier order is the system's own (⌃⌥⇧⌘), so a shortcut shown here
    /// reads exactly as it would in any menu.
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    } // End of displayString

    /// How the key itself is drawn: its symbol when it has one, otherwise the
    /// character the keyboard layout in use produces for it.
    private var keyLabel: String {
        if let symbol = HotKeyCombination.symbols[Int(keyCode)] { return symbol }
        if let character = HotKeyCombination.character(for: keyCode) { return character }
        // Nothing sensible to draw. The raw code at least tells two unknown keys
        // apart, which a bare "?" would not.
        return "#\(keyCode)"
    }

    /// Keys drawn as a glyph rather than as the character they type.
    ///
    /// Deliberately not localised: these are the glyphs macOS prints on its own
    /// menus in every language.
    private static let symbols: [Int: String] = [
        kVK_Space: "␣",
        kVK_Return: "↩",
        kVK_ANSI_KeypadEnter: "⌅",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20"
    ]

    /// Asks the active keyboard layout what a key code types.
    ///
    /// Hard-coding a key code to character table would be wrong for every layout
    /// but the one it was written on: the key that types `Z` on QWERTY types `W`
    /// on AZERTY, and both report the same code. Only the layout knows.
    ///
    /// - Parameter keyCode: the virtual key code to translate.
    /// - Returns: the character, upper-cased as shortcuts are always printed, or
    ///   `nil` when the layout has nothing to say about that key.
    private static func character(for keyCode: UInt32) -> String? {
        // An input method (rather than a plain layout) can be current and carry no
        // layout data at all, hence the ASCII-capable fallback.
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source,
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout,
                                    UInt16(keyCode),
                                    UInt16(kUCKeyActionDisplay),
                                    0,
                                    UInt32(LMGetKbdType()),
                                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                    &deadKeyState,
                                    characters.count,
                                    &length,
                                    &characters)
        guard status == noErr, length > 0 else { return nil }

        return String(utf16CodeUnits: characters, count: length).uppercased()
    } // End of character(for:)
}
