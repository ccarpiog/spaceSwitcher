import Combine
import Foundation

/// Everything the user can change, stored in `UserDefaults` and published so that
/// the settings UI and the parts of the app that react to a setting stay in step
/// without either knowing about the other.
///
/// One store rather than scattered `UserDefaults` reads: a preference that is only
/// read at launch cannot be toggled live, and every setting here is meant to take
/// effect the moment it is flipped.
///
/// Main-actor isolated on purpose. `@Published` notifies subscribers on whichever
/// thread mutated the property, and those subscribers go straight to `NSStatusBar`
/// and to SwiftUI — both main-thread-only. Isolating the store is what makes that
/// safe at the source, rather than leaving every subscriber to hop for itself.
@MainActor
final class Preferences: ObservableObject {

    /// The instance the app runs on. The initialiser still takes a store so a
    /// throwaway `UserDefaults` can be substituted without touching the real one.
    static let shared = Preferences()

    /// Defaults keys, namespaced with the bundle identifier. The app is
    /// non-sandboxed and writes into the shared `standard` domain, so unprefixed
    /// names like `"showsMenuBarIcon"` would be an invitation to collide.
    private enum Key {
        static let showsMenuBarIcon = "cc.carpio.spaceSwitcher.showsMenuBarIcon"
        static let hotKeyCode = "cc.carpio.spaceSwitcher.hotKeyCode"
        static let hotKeyModifiers = "cc.carpio.spaceSwitcher.hotKeyModifiers"
        static let spaceNames = "cc.carpio.spaceSwitcher.spaceNames"

        // There is deliberately no key for the login item: `SMAppService` holds
        // that state, and a copy of it here would go stale the moment the user
        // revoked it in System Settings.
    }

    private let defaults: UserDefaults

    /// Whether a status item is shown in the menu bar.
    ///
    /// Off by default. The app is deliberately menu-less — the hotkey is the whole
    /// interface, see `CLAUDE.md` — so the icon is opt-in and an untouched install
    /// behaves exactly as it did before this setting existed.
    @Published var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) }
    }

    /// The global shortcut that opens the panel.
    ///
    /// Stored as one value rather than as two properties: a key code and a
    /// modifier mask published separately would emit an intermediate combination
    /// that was never asked for, and whoever registers it would briefly claim it.
    ///
    /// Written only after Carbon has accepted the combination — see
    /// `HotKeyController` — so what is stored here is always a shortcut that works.
    @Published var hotKey: HotKeyCombination {
        didSet {
            defaults.set(Int(hotKey.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(hotKey.modifiers), forKey: Key.hotKeyModifiers)
        }
    }

    /// The names the user has given individual Spaces, keyed by `Space.nameKey`.
    ///
    /// Keyed by SkyLight's per-Space `uuid`, which macOS persists itself, so the
    /// names outlive a reboot. Space *ids* are deliberately nowhere in here: they
    /// are handed out afresh whenever a Space is added or removed and mean nothing
    /// between launches — see `CLAUDE.md`.
    ///
    /// `private(set)` with a mutator rather than a freely assignable property. A
    /// blank name has to delete its entry rather than be written as an empty
    /// string, and an open dictionary would let one straight in.
    @Published private(set) var spaceNames: [String: String] {
        didSet { defaults.set(spaceNames, forKey: Key.spaceNames) }
    }

    /// - Parameter defaults: the store to read from and write to.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` answers false for a key that was never written, which is
        // exactly the wanted default, so no registration domain is needed.
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        hotKey = Preferences.readHotKey(from: defaults)
        spaceNames = Preferences.readSpaceNames(from: defaults)
    }

    // MARK: - Space names

    /// The name the user gave one Space, exactly as they typed it.
    ///
    /// - Parameter key: the Space's `nameKey`.
    /// - Returns: the stored name, or `nil` when the Space has none.
    func spaceName(for key: String) -> String? {
        spaceNames[key]
    }

    /// Records the name of one Space, or clears it when there is nothing left of
    /// what was typed.
    ///
    /// The name is stored verbatim rather than trimmed. Trimming on the way in
    /// would swallow a trailing space the instant it was typed, which makes a
    /// two-word name impossible to enter; blankness is judged on a trimmed copy
    /// instead, and everything that reads a name back normalises it.
    ///
    /// Verbatim within reason: `Space.sanitisedName(_:)` still takes out anything
    /// that would reshape the label the name ends up in — newlines above all — and
    /// caps the length. It touches no whitespace, so the trailing space survives.
    ///
    /// - Parameters:
    ///   - name: what the user typed. Empty or all whitespace removes the entry.
    ///   - key: the Space's `nameKey`. An empty key is refused — it would file
    ///     every unidentifiable Space under one name.
    func setSpaceName(_ name: String, for key: String) {
        guard !key.isEmpty else { return }
        let sanitised = Space.sanitisedName(name)
        if Space.normalisedName(sanitised) == nil {
            spaceNames.removeValue(forKey: key)
        } else {
            spaceNames[key] = sanitised
        }
    } // End of setSpaceName(_:for:)

    /// Reads the stored shortcut, falling back to the default whenever what is
    /// there cannot be trusted.
    ///
    /// The checks are not paranoia about our own writes but about the store: this
    /// app is non-sandboxed and its defaults are plain text anyone can edit. A
    /// negative number would trap the `UInt32` conversion, and a combination with
    /// no modifier would claim a bare key in every application on the machine.
    ///
    /// - Parameter defaults: the store to read from.
    /// - Returns: the stored shortcut, or `HotKeyCombination.default`.
    private static func readHotKey(from defaults: UserDefaults) -> HotKeyCombination {
        guard let storedCode = defaults.object(forKey: Key.hotKeyCode) as? Int,
              let storedModifiers = defaults.object(forKey: Key.hotKeyModifiers) as? Int,
              let keyCode = UInt32(exactly: storedCode),
              let modifiers = UInt32(exactly: storedModifiers)
        else { return .default }

        let combination = HotKeyCombination(keyCode: keyCode, modifiers: modifiers)
        return combination.hasModifier ? combination : .default
    } // End of readHotKey(from:)

    /// Reads the stored Space names, keeping only the entries that make sense.
    ///
    /// Same reasoning as `readHotKey(from:)`: the app is non-sandboxed and its
    /// defaults are plain text anyone can edit. `dictionary(forKey:)` already
    /// answers `nil` rather than trapping when the value is not a dictionary at
    /// all, so what is left to guard is the contents — a non-string value, a
    /// blank name, or an empty key that no Space could ever match.
    ///
    /// The names are sanitised on the way out as well as on the way in, because a
    /// store this app did not write is exactly the case being guarded against: a
    /// value carrying newlines would otherwise be handed straight to the HUD and
    /// turn one row into several.
    ///
    /// - Parameter defaults: the store to read from.
    /// - Returns: the usable entries, sanitised, possibly none.
    private static func readSpaceNames(from defaults: UserDefaults) -> [String: String] {
        guard let stored = defaults.dictionary(forKey: Key.spaceNames) else { return [:] }

        var names: [String: String] = [:]
        for (key, value) in stored {
            guard !key.isEmpty,
                  let name = value as? String,
                  Space.normalisedName(name) != nil
            else { continue }
            names[key] = Space.sanitisedName(name)
        } // End of the loop keeping only the stored entries that make sense
        return names
    } // End of readSpaceNames(from:)
}
