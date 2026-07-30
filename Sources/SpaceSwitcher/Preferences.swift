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

        // Reserved for the later phase, named here so it stays consistent when it
        // arrives. Not read or written yet.
        //
        //   cc.carpio.spaceSwitcher.spaceNames       — Space uuid → name (phase 3)
        //
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

    /// - Parameter defaults: the store to read from and write to.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` answers false for a key that was never written, which is
        // exactly the wanted default, so no registration domain is needed.
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        hotKey = Preferences.readHotKey(from: defaults)
    }

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
}
