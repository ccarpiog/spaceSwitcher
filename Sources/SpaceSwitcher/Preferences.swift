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

        // Reserved for the later phases, named here so they stay consistent when
        // they arrive. None of them are read or written yet.
        //
        //   cc.carpio.spaceSwitcher.hotKeyCode       — configurable hotkey (phase 2)
        //   cc.carpio.spaceSwitcher.hotKeyModifiers  — configurable hotkey (phase 2)
        //   cc.carpio.spaceSwitcher.opensAtLogin     — SMAppService state (phase 2)
        //   cc.carpio.spaceSwitcher.spaceNames       — Space uuid → name (phase 3)
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

    /// - Parameter defaults: the store to read from and write to.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` answers false for a key that was never written, which is
        // exactly the wanted default, so no registration domain is needed.
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
    }
}
