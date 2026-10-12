import SwiftUI

/// A rounded square holding an SF Symbol, usually tinted with a subject's colour.
struct IconTile: View {
    let systemName: String
    var foreground: Color = Theme.primaryText
    var background: Color = Color.white.opacity(0.1)
    var size: CGFloat = 36
    var cornerRadius: CGFloat = Theme.Radius.tile
    var symbolSize: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: symbolSize))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(background))
            .accessibilityHidden(true)
    }
}

struct SubjectDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// The grey heading above a section, such as "Recently sorted".
struct SectionTitle: View {
    let title: Text
    var leadingInset: CGFloat = 4

    init(_ title: LocalizedStringKey, leadingInset: CGFloat = 4) {
        self.title = Text(title)
        self.leadingInset = leadingInset
    }

    /// A heading that's already in the student's language, such as "Courses".
    init(verbatim title: String, leadingInset: CGFloat = 4) {
        self.title = Text(verbatim: title)
        self.leadingInset = leadingInset
    }

    var body: some View {
        title
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.leading, leadingInset)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A capsule saying where a file went, such as "Physics · Notes".
struct LocationPill: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            SubjectDot(color: color)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(height: 26)
        .background(Capsule().fill(Theme.selection))
    }
}

/// A slim note above a page's content, such as when Apple Intelligence is off.
struct NoticeBanner: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.secondaryText)
            Text(text)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        .accessibilityElement(children: .combine)
    }
}

/// A card for a subject or a folder: tinted folder icon, name and file count.
struct FolderCard: View {
    static let minHeight: CGFloat = 118

    let title: String
    let subtitle: String
    let foreground: Color
    let background: Color
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { card }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(systemName: "folder", foreground: foreground, background: background)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(isHovered && action != nil ? Theme.cardHover : Theme.cardBackground)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// The toolbar's "Add Files" button.
struct AddFilesButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.isImporting = true
        } label: {
            Label("Add Files", systemImage: "plus")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .help("Add files to sort (⌘O)")
    }
}

/// Lays views out in rows, wrapping to a new row when one fills up.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
