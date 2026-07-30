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
    /// SkyLight's per-Space UUID, or `""` when it reports none.
    ///
    /// The one handle on a Space that outlives the session: macOS persists the
    /// same value in `com.apple.spaces.plist`, so it survives a reboot, whereas
    /// `id` is reassigned whenever a Space is added or removed. It is therefore
    /// what a user-chosen name is filed under — see `nameKey`.
    let uuid: String
    /// Key under which this Space's custom name is stored, or `nil` when it has
    /// no handle worth storing one under.
    ///
    /// Resolved once by `SpaceEnumerator`, not recomputed on demand: deriving it
    /// needs to know whether the Space sits on the primary display, which is a
    /// question about the machine rather than about this value.
    let nameKey: String?
    /// Position within the display, one-based, for display to the user.
    var numberOnDisplay: Int { indexOnDisplay + 1 }
    let kind: SpaceKind
    /// Whether this is the Space currently on screen.
    let isActive: Bool
    /// Names of the apps with a window on this Space, alphabetically. macOS
    /// gives desktops no names, so this is the only meaningful label available.
    let appNames: [String]
    /// The name the user gave this Space, already normalised, or `nil` when they
    /// have not named it. An override on `generatedTitle`, never a replacement:
    /// clearing it puts the generated label straight back.
    let customName: String?

    /// The line shown under the Space's title: the apps present, or a localized
    /// "empty" marker.
    var subtitle: String {
        appNames.isEmpty
            ? NSLocalizedString("space.empty", comment: "Shown for a Space with no windows")
            : appNames.joined(separator: " · ")
    }

    /// The Space's title: whatever the user called it, or the generated label.
    var title: String { customName ?? generatedTitle }

    /// The label macOS's own information yields. Fullscreen Spaces are named
    /// after the app filling them; desktops fall back to their number.
    ///
    /// Kept separate from `title` so the settings list can offer it as the
    /// placeholder of the name field — an empty field then shows exactly what
    /// clearing the name would restore.
    var generatedTitle: String {
        if kind == .fullscreen, let app = appNames.first {
            return app
        }
        let format = NSLocalizedString("space.desktop.number",
                                       comment: "Title for a normal desktop, takes its number")
        return String(format: format, numberOnDisplay)
    }

    /// Whether the user may give this Space a name of their own.
    ///
    /// Desktops that have somewhere to file the name. A fullscreen Space lives
    /// only as long as its app stays fullscreen and is built afresh — with a new
    /// `uuid` — the next time, so a name given to one would quietly stop applying
    /// and leave an entry in the store that nothing can ever match again. It is
    /// also the one kind of Space macOS already names well, after the app filling
    /// it. A Space with no `nameKey` is left out for the plainer reason that
    /// there is nowhere to put the name at all.
    var isRenameable: Bool { kind != .fullscreen && nameKey != nil }

    /// Identity of this Space's row in a SwiftUI list.
    ///
    /// Deliberately not `id`: SkyLight hands Space ids out afresh whenever a
    /// Space is added or removed, so one can come back attached to a different
    /// Space between two refreshes. `ForEach` would then take the row for the one
    /// it drew before and hold the text field's focus on it while the key
    /// underneath had moved, which puts the next keystrokes into another Space's
    /// name.
    ///
    /// For anything renameable this *is* the `nameKey`, so identity and storage
    /// key cannot drift apart: a row keeps its focus exactly as long as it keeps
    /// writing to the same entry. Spaces with no key — never editable ones — fall
    /// back to their position under a prefix of their own, which keeps them
    /// distinct from each other and from every key.
    var rowIdentity: String {
        nameKey ?? "unkeyed:\(displayID)#\(indexOnDisplay)"
    }

    /// Builds the storage key for a Space at a given position, or reports that it
    /// has none.
    ///
    /// The `uuid` whenever SkyLight reports one, because that is the only value
    /// that means the same thing after a reboot.
    ///
    /// Exactly one Space reports an *empty* `uuid`: the primary display's first
    /// one. Verified on this machine — a second display's first Space carries a
    /// real uuid, so this is about the primary display and not about the first
    /// Space of each display — and macOS stores that value empty in
    /// `com.apple.spaces.plist` too. That Space, and only that one, falls back to
    /// its position, because a position is the only handle it has. Any other
    /// Space that ever turns up without a uuid gets no key and is simply not
    /// renameable, the same way a fullscreen Space is not.
    ///
    /// Confining the fallback to a single position is what keeps the weakness of
    /// positional keying to one case: a positional entry can only ever exist at
    /// that one position, so a uuid-bearing Space can never inherit a stale one.
    /// The residual risk is accepted rather than solved — remove the primary
    /// display's first Space and its successor takes the name over, since "first
    /// Space of the primary display" is all the key ever said. The tempting cure,
    /// deleting entries that match no live Space, is worse: unplug a display for
    /// an afternoon and its Spaces' names would go with it.
    ///
    /// The `position:` prefix keeps the two key spaces from meeting. A display
    /// identifier is itself a UUID string, so an unprefixed positional key could
    /// otherwise be read as a Space uuid.
    ///
    /// - Parameters:
    ///   - uuid: SkyLight's per-Space UUID, possibly empty.
    ///   - displayID: identifier of the display the Space sits on.
    ///   - index: zero-based position within that display's Space list.
    ///   - isPrimaryDisplay: whether that display is the primary one.
    /// - Returns: the key, or `nil` when this Space has no handle a name could
    ///   survive under.
    static func nameKey(uuid: String,
                        displayID: String,
                        index: Int,
                        isPrimaryDisplay: Bool) -> String? {
        if !uuid.isEmpty { return uuid }
        guard isPrimaryDisplay, index == 0 else { return nil }
        return "position:\(displayID)#\(index)"
    } // End of nameKey(uuid:displayID:index:isPrimaryDisplay:)

    /// The greatest number of characters a Space name may keep.
    ///
    /// Robustness rather than tidiness. The HUD is a fixed 420 points wide and
    /// the name is its title line, so a value of no particular length — pasted in,
    /// written straight into the defaults, or just typed at length into the
    /// settings field — is a value the panel has to find room for. The label
    /// truncates as well; this stops anything unusable reaching the store in the
    /// first place.
    static let maximumNameLength = 60

    /// Scalars a name may never contain, wherever it came from.
    ///
    /// Newlines and the other control characters are the ones that matter: they
    /// break the HUD's single-line title into several lines and push the panel's
    /// height about, so `"Work\nInjected row"` reads as a second row that is not
    /// a Space at all.
    ///
    /// `\u{200D}` is spared on purpose. Unicode files the zero-width joiner as a
    /// control character, but it is what holds a multi-part emoji together, and
    /// replacing it would take a name someone deliberately typed as "👨‍👩‍👧"
    /// apart into three.
    private static let forbiddenScalars: CharacterSet = CharacterSet.controlCharacters
        .union(.newlines)
        .subtracting(CharacterSet(charactersIn: "\u{200D}"))

    /// Makes a name safe to draw and to store, without getting in the way of what
    /// the user can legitimately type.
    ///
    /// Every forbidden scalar becomes one space rather than vanishing, so a
    /// pasted `"Work\nHome"` reads as `"Work Home"` instead of `"WorkHome"`, and
    /// what is left is cut to `maximumNameLength`.
    ///
    /// Whitespace is deliberately neither collapsed nor trimmed here. This runs on
    /// every keystroke, and a trailing space swallowed as it is typed makes a
    /// two-word name impossible to enter; judging blankness stays
    /// `normalisedName(_:)`'s job.
    ///
    /// - Parameter raw: the name as stored or as typed.
    /// - Returns: the same name with nothing left in it that could reshape a label.
    static func sanitisedName(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            forbiddenScalars.contains($0) ? " " : $0
        }))
        return String(cleaned.prefix(maximumNameLength))
    } // End of sanitisedName(_:)

    /// Sanitises and trims a stored name, and reports `nil` for one that says
    /// nothing.
    ///
    /// The single definition of "blank" in the app. An empty or whitespace-only
    /// name means the Space has no name of its own, so the entry is dropped
    /// rather than written as an empty string, and the generated label comes
    /// back.
    ///
    /// Sanitising happens here as well as on the way in because the store cannot
    /// be assumed clean: the app is non-sandboxed and its defaults are plain text
    /// anyone can edit, so a name written before this rule existed — or written by
    /// hand — still has to be safe by the time it reaches a label.
    ///
    /// - Parameter raw: the name as stored or as typed.
    /// - Returns: the sanitised, trimmed name, or `nil` when there is nothing left
    ///   of it.
    static func normalisedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = sanitisedName(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    } // End of normalisedName(_:)
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

    /// Enumerates every display and its Spaces, labelled with the apps present
    /// and with whatever names the user has given them.
    ///
    /// Space ids are re-read on every call because they are not stable across
    /// Space creation/removal or reboots.
    ///
    /// - Parameter customNames: the stored names, keyed by `Space.nameKey`.
    ///   Passed in as a plain snapshot rather than read from `Preferences` here,
    ///   so this stays a value type with no actor isolation of its own.
    func enumerate(customNames: [String: String] = [:]) -> [DisplaySpaces] {
        let activeSpace = bridge.activeSpaceID()
        let appsBySpace = appNamesBySpace()
        let displayNames = displayNamesByUUID()
        // Read once for the whole enumeration: it is what tells the single Space
        // allowed a positional name key from every other uuid-less one.
        let primaryDisplayID = NSScreenAdapter.primaryDisplayUUID()

        return bridge.managedDisplaySpaces().compactMap { display -> DisplaySpaces? in
            guard let displayID = display["Display Identifier"] as? String,
                  let rawSpaces = display["Spaces"] as? [[String: Any]]
            else { return nil }
            // Core Graphics names the primary display with the same UUID string
            // SkyLight puts in "Display Identifier" — verified on this machine.
            // Should that ever stop holding, no display matches, no positional key
            // is derived, and the affected Space is listed but not renameable.
            let isPrimaryDisplay = primaryDisplayID != nil && displayID == primaryDisplayID

            let spaces = rawSpaces.enumerated().compactMap { index, raw -> Space? in
                guard let id = raw["ManagedSpaceID"] as? UInt64 ?? raw["id64"] as? UInt64
                else { return nil }
                // SkyLight reports the uuid as an empty string for the primary
                // display's first Space, which `Space.nameKey` handles; a missing
                // key is treated the same way rather than trusted to exist.
                let uuid = raw["uuid"] as? String ?? ""
                let kind = SpaceKind(raw: raw["type"] as? Int ?? -1)
                let key = Space.nameKey(uuid: uuid,
                                        displayID: displayID,
                                        index: index,
                                        isPrimaryDisplay: isPrimaryDisplay)
                // Fullscreen Spaces are not renameable, so any entry matching one
                // is ignored instead of shown: it can only be a leftover from a
                // Space that has since been rebuilt under a new uuid.
                let name: String? = kind == .fullscreen
                    ? nil
                    : key.flatMap { Space.normalisedName(customNames[$0]) }
                return Space(
                    id: id,
                    displayID: displayID,
                    indexOnDisplay: index,
                    uuid: uuid,
                    nameKey: key,
                    kind: kind,
                    isActive: id == activeSpace,
                    appNames: (appsBySpace[id] ?? []).sorted(),
                    customName: name
                )
            } // End of the map over one display's raw Spaces

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
