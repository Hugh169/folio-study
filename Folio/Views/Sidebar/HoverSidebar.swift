import SwiftUI

/// The rail on the left. Collapsed it shows icons only; when the pointer rests
/// on it, or keyboard focus moves into it, it opens to show labels, pushing the
/// page across rather than covering it.
struct HoverSidebar: View {
    static let collapsedWidth: CGFloat = 72
    static let expandedWidth: CGFloat = 208
    /// How long the pointer rests on the rail before it opens.
    static let openDelay: Duration = .milliseconds(140)

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.toolbarHeight) private var toolbarHeight

    @State private var isHovering = false
    @State private var isExpanded: Bool
    @State private var pendingOpen: Task<Void, Never>?
    @FocusState private var focusedItem: Destination?

    /// - Parameter startsExpanded: Show the open state straight away, for previews.
    init(startsExpanded: Bool = false) {
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's traffic-light buttons sit in this space.
            Color.clear.frame(height: toolbarHeight)

            VStack(spacing: 2) {
                item(.today, title: String(localized: "Today")) {
                    Image(systemName: "sun.max")
                }
                item(.inbox, title: String(localized: "Inbox"), badge: inboxBadge) {
                    Image(systemName: "tray")
                }
                item(.planner, title: String(localized: "Planner")) {
                    Image(systemName: "calendar")
                }
                item(.study, title: String(localized: "Study"), badge: studyBadge) {
                    Image(systemName: "graduationcap")
                }
                item(.library, title: String(localized: "Library")) {
                    Image(systemName: "square.grid.2x2")
                }
                item(.progress, title: String(localized: "Progress")) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                }
            }

            SidebarSectionHeader(title: model.subjectsTitle, isExpanded: isExpanded, animates: !reduceMotion)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.subjects) { subject in
                        item(.subject(subject.id), title: subject.name) {
                            SubjectDot(color: subject.color)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 16)
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBackground)
        .overlay(alignment: .trailing) {
            // The border starts below the toolbar band: the real traffic-light
            // buttons are wider than the collapsed rail and would sit on it.
            Rectangle()
                .fill(Theme.gridLine)
                .frame(width: 1)
                .padding(.top, toolbarHeight)
        }
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            updateExpansion()
        }
        .onChange(of: focusedItem) {
            updateExpansion()
        }
        .onDisappear {
            pendingOpen?.cancel()
        }
    }

    /// Cards waiting to be reviewed, as the Study item's badge.
    private var studyBadge: String? {
        let due = model.dueCards().count
        return due == 0 ? nil : String(localized: "\(due) cards to review")
    }

    private var inboxBadge: String? {
        switch model.needsReview.count {
        case 0: nil
        case let count: String(localized: "\(count) files need a look")
        }
    }

    /// Labels slide in just after the rail starts opening, and fade quickly when it closes.
    private var labelAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return isExpanded ? .spring(duration: 0.45, bounce: 0.3).delay(0.12) : .easeOut(duration: 0.15)
    }

    private func item<Icon: View>(
        _ destination: Destination,
        title: String,
        badge: String? = nil,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        SidebarItem(
            title: title,
            badge: badge,
            isSelected: model.destination == destination,
            isExpanded: isExpanded,
            isFocused: focusedItem == destination,
            labelAnimation: labelAnimation,
            action: { model.destination = destination },
            icon: icon
        )
        .focused($focusedItem, equals: destination)
    }

    private func updateExpansion() {
        let wantsExpanded = isHovering || focusedItem != nil
        pendingOpen?.cancel()
        pendingOpen = nil
        guard wantsExpanded != isExpanded else { return }

        if reduceMotion {
            // Open and close instantly.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isExpanded = wantsExpanded }
        } else if wantsExpanded {
            pendingOpen = Task {
                try? await Task.sleep(for: Self.openDelay)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.5, bounce: 0.22)) { isExpanded = true }
            }
        } else {
            // Close quickly, with no spring.
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { isExpanded = false }
        }
    }
}

private struct SidebarItem<Icon: View>: View {
    let title: String
    let badge: String?
    let isSelected: Bool
    let isExpanded: Bool
    let isFocused: Bool
    let labelAnimation: Animation?
    let action: () -> Void
    @ViewBuilder let icon: Icon

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.sidebarIcon)
                    .frame(width: 18, height: 18)
                    .overlay(alignment: .topTrailing) {
                        if badge != nil {
                            BadgeDot().offset(x: 5, y: -4)
                        }
                    }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.primaryText.opacity(isSelected ? 1 : 0.82))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.96, anchor: .leading)
                    .offset(x: isExpanded ? 0 : -10)
                    .animation(labelAnimation, value: isExpanded)
            }
            .padding(.leading, 17)
            // minWidth 0 keeps the row at the rail's width while the label overflows to the right.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(rowFill))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile + 2)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .padding(-2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(badge ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowFill: Color {
        if isSelected { return Theme.selection }
        return isHovered ? Theme.hover : .clear
    }
}

/// The small accent dot on Inbox when something needs a look.
private struct BadgeDot: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 8, height: 8)
            .padding(2)
            .background(Circle().fill(Theme.windowBackground))
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Sidebar, open") {
    HoverSidebar(startsExpanded: true)
        .environment(AppModel.sample())
        .frame(height: 600)
}
#endif

/// Collapsed, a short divider; expanded, the section title.
private struct SidebarSectionHeader: View {
    let title: String
    let isExpanded: Bool
    let animates: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 20, height: 1)
                .opacity(isExpanded ? 0 : 1)
                .animation(animates ? .easeOut(duration: 0.15) : nil, value: isExpanded)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize()
                .opacity(isExpanded ? 1 : 0)
                .animation(animates ? (isExpanded ? .easeOut(duration: 0.2).delay(0.16) : .easeOut(duration: 0.15)) : nil, value: isExpanded)
        }
        .padding(.leading, 17)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 14)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}
