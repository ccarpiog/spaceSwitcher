import SwiftUI

/// Backing state for the HUD, refreshed every time the panel opens.
final class HUDViewModel: ObservableObject {
    /// Displays and their Spaces, in SkyLight's ordering.
    @Published var displays: [DisplaySpaces] = []
    /// Index into `rows` of the highlighted entry.
    @Published var selection: Int = 0
    /// A problem that leaves nothing to show, so it replaces the list entirely.
    /// Only set when the Spaces layout cannot be read at all.
    @Published var fatalMessage: String?
    /// A warning shown *above* the list without hiding it. The Spaces are still
    /// listed and still selectable — anything that merely affects jumping belongs
    /// here, never in `fatalMessage`.
    @Published var notice: String?

    /// One selectable line: a Space plus the display it belongs to.
    struct Row: Identifiable {
        let id: UInt64
        let space: Space
        let display: DisplaySpaces
        /// The digit the user can press to jump straight here, when it fits in 1–9.
        let shortcut: Int?
    }

    /// Flattens the per-display structure into the selectable list the view draws.
    var rows: [Row] {
        var result: [Row] = []
        for display in displays {
            for space in display.spaces {
                let position = result.count + 1
                result.append(Row(id: space.id,
                                  space: space,
                                  display: display,
                                  shortcut: position <= 9 ? position : nil))
            }
        }
        return result
    }

    /// Whether display headings are worth drawing at all.
    var showsDisplayHeadings: Bool { displays.count > 1 }

    /// Moves the highlight by `offset`, clamped to the ends rather than wrapping,
    /// which matches how the arrow keys behave elsewhere in macOS.
    func moveSelection(by offset: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(selection + offset, 0), count - 1)
    }

    /// Points the highlight at the Space *after* the one currently on screen,
    /// wrapping around at the end.
    ///
    /// Highlighting the active Space instead would make the most natural gesture —
    /// open the panel, press Return — do nothing at all: the panel would close and
    /// the user would stay exactly where they were, looking like a broken jump.
    /// This matches the app switcher, which preselects the next item rather than
    /// the current one. The "current" badge still shows where you are.
    func selectDefault() {
        guard !rows.isEmpty else {
            selection = 0
            return
        }
        if let activeIndex = rows.firstIndex(where: { $0.space.isActive }) {
            selection = (activeIndex + 1) % rows.count
        } else {
            selection = 0
        }
    } // End of selectDefault()
}

/// The HUD's contents: a list of Spaces with the apps on each, plus a key hint bar.
struct HUDView: View {

    @ObservedObject var model: HUDViewModel
    /// Invoked with the chosen row when the user commits a selection.
    var onChoose: (HUDViewModel.Row) -> Void
    /// Invoked when the user asks for the Settings window.
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fatalMessage = model.fatalMessage {
                Text(fatalMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // A notice never replaces the list: the Spaces stay visible and
                // selectable, because a warning about jumping is useless if it
                // hides the thing the user came here to pick.
                if let notice = model.notice {
                    noticeBanner(notice)
                }
                spaceList
            }
            Divider().opacity(0.5)
            hintBar
        }
        .frame(width: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// A warning strip above the list, visually distinct but not blocking.
    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 3)
    }

    /// The scrollable list of Spaces, grouped by display when there is more than one.
    private var spaceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.displays.enumerated()), id: \.element.id) { _, display in
                if model.showsDisplayHeadings {
                    Text(display.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                }
                ForEach(rows(for: display)) { row in
                    SpaceRowView(row: row, isSelected: isSelected(row))
                        .contentShape(Rectangle())
                        .onTapGesture { onChoose(row) }
                }
            } // End of the loop drawing each display and the Spaces beneath it
        }
        .padding(.vertical, 6)
    }

    /// The bottom bar reminding the user which keys do what.
    private var hintBar: some View {
        HStack(spacing: 14) {
            hint("↑↓", NSLocalizedString("hud.hint.select", comment: "Arrow keys move the highlight"))
            hint("⏎", NSLocalizedString("hud.hint.jump", comment: "Return jumps to the Space"))
            hint("esc", NSLocalizedString("hud.hint.cancel", comment: "Escape closes the panel"))
            hint("q", NSLocalizedString("hud.hint.quit", comment: "Q quits the app"))
            Spacer()
            settingsButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// The way into Settings from the panel.
    ///
    /// Just an icon, tucked into the corner of the hint bar: the panel exists to be
    /// dismissed in a keystroke, and a labelled button would compete for attention
    /// with the Spaces the user actually came here to pick.
    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(settingsLabel)
        .accessibilityLabel(settingsLabel)
    }

    /// Shared title for the gear button's tooltip and its accessibility label.
    private var settingsLabel: String {
        NSLocalizedString("hud.settings", comment: "Gear button in the panel that opens Settings")
    }

    /// One key-plus-label pair in the hint bar.
    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// The rows belonging to one display.
    private func rows(for display: DisplaySpaces) -> [HUDViewModel.Row] {
        model.rows.filter { $0.display.id == display.id }
    }

    /// Whether a row is the highlighted one.
    private func isSelected(_ row: HUDViewModel.Row) -> Bool {
        guard model.selection < model.rows.count else { return false }
        return model.rows[model.selection].id == row.id
    }
}

/// A single Space row: shortcut digit, title, the apps on it, and an active marker.
private struct SpaceRowView: View {

    let row: HUDViewModel.Row
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(row.shortcut.map(String.init) ?? " ")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.space.title)
                        .font(.system(size: 13, weight: .medium))
                    if row.space.isActive {
                        Text(NSLocalizedString("space.current",
                                               comment: "Marker on the Space already on screen"))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.10), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.space.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : .clear)
                .padding(.horizontal, 4)
        )
    }
}
