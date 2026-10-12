import SwiftUI
import FolioKit

/// Shown when nothing in the Inbox needs the student.
struct AllCaughtUp: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: "checkmark", foreground: Theme.success, background: Theme.success.opacity(0.16), symbolSize: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're all caught up")
                    .font(.system(size: 14, weight: .medium))
                Text("Files Folio isn't sure about, and tasks it finds in your files, wait here for you.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
        .accessibilityElement(children: .combine)
    }
}

/// Files sorted in the last week, by subject.
struct SortedThisWeek: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let weekAgo = model.calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        let recent = model.recentlySorted.filter { $0.sortedAt >= weekAgo }
        let counts = Dictionary(grouping: recent, by: \.subjectID).mapValues(\.count)
        let subjects = model.subjects.filter { counts[$0.id] != nil }.sorted { counts[$0.id] ?? 0 > counts[$1.id] ?? 0 }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Sorted this week")
                Spacer()
                Text(fileCountText(recent.count))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 12) {
                if subjects.isEmpty {
                    Text("Nothing yet this week. Files you drop here, and downloads Folio watches, are filed by subject.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // One bar, split by subject, then each subject's count.
                    GeometryReader { proxy in
                        HStack(spacing: 2) {
                            ForEach(subjects) { subject in
                                Rectangle()
                                    .fill(subject.color)
                                    .frame(width: max(4, (proxy.size.width - CGFloat(subjects.count - 1) * 2) * CGFloat(counts[subject.id] ?? 0) / CGFloat(max(recent.count, 1))))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)
                    .accessibilityHidden(true)
                    FlowLayout(spacing: 8) {
                        ForEach(subjects) { subject in
                            LocationPill(color: subject.color, text: "\(subject.name) \((counts[subject.id] ?? 0).formatted())")
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        }
    }
}

/// How sorting works, in three steps, for a student who hasn't sorted anything yet.
struct HowSortingWorks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("How Folio sorts")
            HStack(spacing: 10) {
                step(1, "doc.text.magnifyingglass", Theme.accent, "Reads it", "Text, scanned pages, slides and even recordings.")
                arrow
                step(2, "sparkles", Theme.purple, "Picks the subject", "From the words in it, your past choices and the on-device AI.")
                arrow
                step(3, "folder", Theme.success, "Files it", "Into the subject's folder. Undo puts it back.")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText)
            .accessibilityHidden(true)
    }

    private func step(_ number: Int, _ systemImage: String, _ colour: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: systemImage, foreground: colour, background: colour.opacity(0.16), size: 34, cornerRadius: 10, symbolSize: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.cardBackground))
        .accessibilityElement(children: .combine)
    }
}

/// Where files reach Folio from: Downloads, other watched folders and the
/// Shortcuts app, each with how it's set up.
struct FileSources: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let downloads = model.watchedFolders.first(where: \.isDownloads)
        let others = model.watchedFolders.filter { !$0.isDownloads && $0.isOn }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Where files come from")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                SourceCard(
                    systemImage: "arrow.down.circle",
                    colour: Theme.accent,
                    title: "Downloads",
                    status: downloads?.isOn == true ? String(localized: "Watching") : String(localized: "Not watched"),
                    isOn: downloads?.isOn == true
                ) {
                    if let downloads {
                        Toggle("Watch Downloads", isOn: Binding(get: { downloads.isOn }, set: { model.setWatching(downloads, on: $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                }
                SourceCard(
                    systemImage: "folder.badge.gearshape",
                    colour: Theme.warning,
                    title: "Other folders",
                    status: others.isEmpty ? String(localized: "None yet") : others.map(\.displayName).formatted(.list(type: .and)),
                    isOn: !others.isEmpty
                ) {
                    Button("Add…") { model.addWatchedFolder() }
                        .buttonStyle(.folioLink)
                        .disabled(model.live == nil)
                }
                SourceCard(
                    systemImage: "square.and.arrow.up",
                    colour: Theme.success,
                    title: "Shortcuts",
                    status: String(localized: "Use “Sort Files” in Shortcuts"),
                    isOn: true
                ) {
                    EmptyView()
                }
            }
        }
    }
}

/// One way files reach Folio, with its status and a control.
private struct SourceCard<Control: View>: View {
    let systemImage: String
    let colour: Color
    let title: LocalizedStringKey
    let status: String
    let isOn: Bool
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: systemImage, foreground: colour, background: colour.opacity(0.16), size: 34, cornerRadius: 10, symbolSize: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOn ? Theme.success : Theme.tertiaryText)
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.cardBackground))
    }
}
