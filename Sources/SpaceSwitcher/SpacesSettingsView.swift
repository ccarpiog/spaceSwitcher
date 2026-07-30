import AppKit
import Combine
import SwiftUI

/// Backing state for the Spaces tab: the layout as it is right now.
///
/// The list is re-read rather than remembered. Space ids and the order Spaces sit
/// in change whenever one is added, removed or dragged about in Mission Control,
/// and nothing tells the app when that happened — so anything kept between two
/// openings of the window is stale by the time it is shown. Only the *names* are
/// persistent, and those live in `Preferences`, not here.
@MainActor
final class SpacesSettingsModel: ObservableObject {

    /// The instance the Settings window uses.
    static let shared = SpacesSettingsModel(preferences: .shared)

    /// Displays and their Spaces, in SkyLight's ordering. Empty until refreshed.
    @Published private(set) var displays: [DisplaySpaces] = []

    /// `true` when the Spaces layout could not be read at all, which means this
    /// macOS release moved the private symbols the app depends on.
    @Published private(set) var isUnavailable = false

    private let enumerator = SpaceEnumerator()
    private let preferences: Preferences

    /// - Parameter preferences: the store holding the names. Passed in with no
    ///   default: a default argument is evaluated in a nonisolated context, which
    ///   cannot touch a main-actor-isolated `static let`.
    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Re-reads the Spaces layout from SkyLight.
    ///
    /// Called every time the tab appears and every time the app comes back to the
    /// front — the user goes to Mission Control to add a Space and returns
    /// expecting to name it.
    func refresh() {
        guard SkyLightBridge.shared.isAvailable else {
            isUnavailable = true
            displays = []
            return
        }
        isUnavailable = false
        displays = enumerator.enumerate(customNames: preferences.spaceNames)
    } // End of refresh()
}

/// The "Spaces" section: every Space on every display, each with a name field.
///
/// Renaming lives here rather than in the HUD panel on purpose. The panel exists
/// to be opened and dismissed in a couple of keystrokes, and an edit mode inside
/// it would fight that.
struct SpacesSettingsView: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var model: SpacesSettingsModel

    var body: some View {
        Form {
            Section {
                note(NSLocalizedString("settings.spaces.detail",
                                       comment: "Explains what the Space name fields do"))
            }

            if model.isUnavailable {
                Section {
                    note(NSLocalizedString(
                        "error.unsupported",
                        comment: "Shown when the private SkyLight symbols cannot be resolved"),
                         isWarning: true)
                }
            } else if model.displays.isEmpty {
                Section {
                    note(NSLocalizedString("settings.spaces.empty",
                                           comment: "Shown when no Spaces could be read"))
                }
            } else {
                ForEach(model.displays) { display in
                    Section {
                        // Keyed by `rowIdentity`, never by `Space.id`: SkyLight
                        // reuses ids, and a reused one would let SwiftUI keep a
                        // field's focus on a row whose Space had changed
                        // underneath it.
                        ForEach(display.spaces, id: \.rowIdentity) { space in
                            row(for: space, on: display)
                        }
                    } header: {
                        Text(display.name)
                    }
                } // End of the loop drawing one section per display
            }
        }
        .formStyle(.grouped)
        // Never cached across openings: the Spaces are whatever they are at the
        // moment the tab is looked at.
        .onAppear(perform: model.refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refresh()
            }
    } // End of body

    /// One Space: what macOS calls it, what is on it, and the field naming it.
    ///
    /// - Parameters:
    ///   - space: the Space this row stands for.
    ///   - display: the display it belongs to, for the "current" marker — which
    ///     is per display, not the single globally active Space.
    private func row(for space: Space, on display: DisplaySpaces) -> some View {
        LabeledContent {
            if space.isRenameable {
                // The prompt is the generated label, so an empty field shows
                // exactly what clearing the name would put back.
                //
                // `prompt:` plus an empty title, rather than the one-argument
                // `TextField(_:text:)`. Inside a `Form` that title is treated as
                // the field's *label* and drawn beside it, which put a second
                // "Desktop 1" next to every row instead of greyed-out text inside
                // the box. `labelsHidden()` then stops the empty title reserving
                // room of its own.
                TextField("", text: nameBinding(for: space),
                          prompt: Text(space.generatedTitle))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    // A grouped `Form` right-aligns what it puts in the trailing
                    // column, which reads oddly for a name being typed and leaves
                    // the prompt hanging as far as possible from the row it
                    // belongs to.
                    .multilineTextAlignment(.leading)
                    .frame(minWidth: 150)
            } else {
                unnameableNote(for: space)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(space.generatedTitle)
                    if space.id == display.currentSpaceID {
                        currentBadge
                    }
                }
                // The apps present are the only way to tell one bare desktop from
                // another, which is the whole problem renaming solves.
                Text(space.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    } // End of row(for:on:)

    /// What takes the place of the name field when a Space cannot be given a name.
    ///
    /// The two reasons are not the same thing to tell the user. A fullscreen Space
    /// already has a good name — its app's — and is rebuilt under a new uuid every
    /// time it is entered, so a name given to one would silently stop applying. A
    /// Space SkyLight reports with no uuid has nowhere for a name to live at all;
    /// on this machine that only ever happens to the primary display's first
    /// Space, which is keyed by position instead and stays renameable, so this
    /// branch is the one for a layout nobody has seen yet.
    ///
    /// - Parameter space: the Space the row stands for.
    @ViewBuilder
    private func unnameableNote(for space: Space) -> some View {
        if space.kind == .fullscreen {
            note(NSLocalizedString(
                "settings.spaces.fullscreen",
                comment: "Shown instead of a name field for a fullscreen Space"))
        } else {
            note(NSLocalizedString(
                "settings.spaces.unnameable",
                comment: "Shown instead of a name field for a Space macOS gives no identifier"))
                .help(NSLocalizedString(
                    "settings.spaces.unnameable.help",
                    comment: "Tooltip explaining why that Space cannot be named"))
        }
    } // End of unnameableNote(for:)

    /// The small marker on whichever Space that display is showing right now.
    private var currentBadge: some View {
        Text(NSLocalizedString("space.current",
                               comment: "Marker on the Space already on screen"))
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.primary.opacity(0.10), in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// Two-way binding between one Space's field and the store.
    ///
    /// The field reads straight from the store rather than from a copy of it. That
    /// is what lets the list underneath be re-enumerated at any moment — which it
    /// is, on every activation — without wiping out what the user is halfway
    /// through typing: the text never came from the enumeration in the first place.
    ///
    /// - Parameter space: the Space being named.
    /// - Returns: a binding that writes through on every keystroke, so the panel
    ///   shows the new name the very next time it opens. Read-only and empty for a
    ///   Space with no key, which `isRenameable` already keeps out of this path.
    private func nameBinding(for space: Space) -> Binding<String> {
        guard let key = space.nameKey else { return .constant("") }
        return Binding(
            get: { preferences.spaceName(for: key) ?? "" },
            set: { preferences.setSpaceName($0, for: key) })
    }

    /// One line of explanatory text, matching the General tab's notes.
    ///
    /// - Parameters:
    ///   - text: the already localised message.
    ///   - isWarning: `true` for something that went wrong, which is tinted rather
    ///     than left in the secondary grey.
    private func note(_ text: String, isWarning: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
