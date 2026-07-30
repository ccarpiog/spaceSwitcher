import SwiftUI

/// Backing state for the HUD, refreshed every time the panel opens.
final class HUDViewModel: ObservableObject {
    /// Displays and their Spaces, in SkyLight's ordering.
    @Published var displays: [DisplaySpaces] = []
    /// Index into `rows` of the highlighted entry.
    @Published var selection: Int = 0
    /// Non-nil when something needs explaining to the user, e.g. a missing permission.
    @Published var message: String?

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

    /// Points the highlight at the Space currently on screen, so pressing the
    /// hotkey and immediately pressing Return is a no-op rather than a surprise.
    func selectActiveSpace() {
        if let index = rows.firstIndex(where: { $0.space.isActive }) {
            selection = index
        }
    }
}

/// The HUD's contents: a list of Spaces with the apps on each, plus a key hint bar.
struct HUDView: View {

    @ObservedObject var model: HUDViewModel
    /// Invoked with the chosen row when the user commits a selection.
    var onChoose: (HUDViewModel.Row) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
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
