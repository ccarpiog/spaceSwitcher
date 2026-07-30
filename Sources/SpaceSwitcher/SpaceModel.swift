import Foundation
import CoreGraphics

/// What kind of Space this is, as reported by SkyLight's `type` field.
enum SpaceKind: Int {
    /// An ordinary Mission Control desktop.
    case desktop = 0
    /// A fullscreen app occupying its own Space.
    case fullscreen = 4
    /// Anything a future macOS introduces.
    case unknown = -1

    /// Maps SkyLight's raw integer to a case without trapping on new values.
    init(raw: Int) {
        self = SpaceKind(rawValue: raw) ?? .unknown
    }
}

/// One Space, resolved and ready to display.
struct Space: Identifiable {
    /// SkyLight's Space id. Valid for this session only — never persisted.
    let id: UInt64
    /// Identifier of the display this Space belongs to.
    let displayID: String
    /// Zero-based position within its display's Space list. This drives the
    /// relative navigation arithmetic, so it must reflect SkyLight's ordering.
    let indexOnDisplay: Int
    /// Position within the display, one-based, for display to the user.
    var numberOnDisplay: Int { indexOnDisplay + 1 }
    let kind: SpaceKind
    /// Whether this is the Space currently on screen.
    let isActive: Bool
    /// Names of the apps with a window on this Space, alphabetically. macOS
    /// gives desktops no names, so this is the only meaningful label available.
    let appNames: [String]

    /// The line shown under the Space's title: the apps present, or a localized
    /// "empty" marker.
    var subtitle: String {
        appNames.isEmpty
            ? NSLocalizedString("space.empty", comment: "Shown for a Space with no windows")
            : appNames.joined(separator: " · ")
    }

    /// The Space's title. Fullscreen Spaces are named after the app filling
    /// them; desktops fall back to their number.
    var title: String {
        if kind == .fullscreen, let app = appNames.first {
            return app
        }
        let format = NSLocalizedString("space.desktop.number",
                                       comment: "Title for a normal desktop, takes its number")
        return String(format: format, numberOnDisplay)
    }
}

/// One display and the Spaces on it.
struct DisplaySpaces: Identifiable {
    let id: String
    /// Human-readable display name, e.g. "Built-in Retina Display".
    let name: String
    let spaces: [Space]
    /// The Space currently showing *on this display*.
    ///
    /// Distinct from the globally active Space: with "Displays have separate
    /// Spaces" enabled every display has its own current Space, and only one of
    /// them is the globally active one. Relative navigation on this display starts
    /// from here, so using the global active Space instead makes every jump to a
    /// non-focused display fail.
    let currentSpaceID: UInt64
}

/// Builds the Space list by combining SkyLight's layout with the window list.
///
/// Everything here is read-only and needs no permission, so the panel can be
/// populated before any TCC prompt has been answered.
struct SpaceEnumerator {

    private let bridge: SkyLightBridge

    /// - Parameter bridge: injected so tests can supply a stub.
    init(bridge: SkyLightBridge = .shared) {
        self.bridge = bridge
    }

    /// Enumerates every display and its Spaces, labelled with the apps present.
    ///
    /// Space ids are re-read on every call because they are not stable across
    /// Space creation/removal or reboots.
    func enumerate() -> [DisplaySpaces] {
        let activeSpace = bridge.activeSpaceID()
        let appsBySpace = appNamesBySpace()
        let displayNames = displayNamesByUUID()

        return bridge.managedDisplaySpaces().compactMap { display -> DisplaySpaces? in
            guard let displayID = display["Display Identifier"] as? String,
                  let rawSpaces = display["Spaces"] as? [[String: Any]]
            else { return nil }

            let spaces = rawSpaces.enumerated().compactMap { index, raw -> Space? in
                guard let id = raw["ManagedSpaceID"] as? UInt64 ?? raw["id64"] as? UInt64
                else { return nil }
                return Space(
                    id: id,
                    displayID: displayID,
                    indexOnDisplay: index,
                    kind: SpaceKind(raw: raw["type"] as? Int ?? -1),
                    isActive: id == activeSpace,
                    appNames: (appsBySpace[id] ?? []).sorted()
                )
            }

            // SkyLight reports each display's own current Space separately from the
            // globally active one. Falling back to the first Space keeps a jump
            // possible even if the key is ever missing.
            let currentOnDisplay = (display["Current Space"] as? [String: Any])
                .flatMap { $0["ManagedSpaceID"] as? UInt64 ?? $0["id64"] as? UInt64 }
                ?? spaces.first?.id ?? 0

            return DisplaySpaces(
                id: displayID,
                name: displayNames[displayID] ?? NSLocalizedString(
                    "display.unknown", comment: "Fallback name for an unidentified display"),
                spaces: spaces,
                currentSpaceID: currentOnDisplay
            )
        } // End of the map over displays, turning raw SkyLight dictionaries into DisplaySpaces
    } // End of enumerate()

    /// Groups the names of app-owning windows by the Space they sit on.
    ///
    /// Only layer-0 windows count — that excludes the Dock, menu bar extras and
    /// other chrome that would otherwise appear on every Space. Windows present
    /// on multiple Spaces are sticky and are skipped, since they do not help
    /// distinguish one Space from another.
    ///
    /// Reads `kCGWindowOwnerName`, which needs no permission. Window *titles*
    /// are deliberately not used: those require Screen Recording access.
    private func appNamesBySpace() -> [UInt64: Set<String>] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return [:] }

        var result: [UInt64: Set<String>] = [:]
        for window in windows {
            guard let windowID = window[kCGWindowNumber as String] as? Int,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  (window[kCGWindowLayer as String] as? Int) == 0
            else { continue }

            let spaces = bridge.spaces(forWindowID: windowID)
            guard spaces.count == 1, let space = spaces.first else { continue }
            result[space, default: []].insert(owner)
        } // End of the loop over every window, bucketing app names by Space
        return result
    } // End of appNamesBySpace()

    /// Maps each display's UUID to its localized product name so the panel can
    /// group Spaces under a recognisable heading.
    private func displayNamesByUUID() -> [String: String] {
        var names: [String: String] = [:]
        for screen in NSScreenAdapter.allScreens() {
            if let uuid = screen.uuid {
                names[uuid] = screen.name
            }
        }
        return names
    }
}
