import SwiftUI
import FolioKit

struct InboxView: View {
    @Environment(AppModel.self) private var model

    /// Files and assessments waiting for the student.
    private var waitingCount: Int {
        model.needsReview.count + model.assessmentSuggestions.count
    }

    /// What's happening: files being sorted, then what's waiting.
    private var subtitle: String {
        let left = model.sorting.filter { !$0.isDone }.count
        if left > 0 { return String(localized: "Sorting \(left) files…") }
        return waitingCount == 0 ? String(localized: "All caught up") : String(localized: "\(waitingCount) waiting")
    }

    private var isClear: Bool {
        model.sorting.isEmpty && waitingCount == 0
    }

    var body: some View {
        Screen(title: "Inbox", subtitle: subtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let notice = model.aiNotice {
                        NoticeBanner(systemImage: "apple.intelligence", text: notice)
                    }

                    DropZone()

                    if !model.sorting.isEmpty {
                        SortingProgressCard(items: model.sorting)
                    }

                    if !model.assessmentSuggestions.isEmpty {
                        AssessmentsFound()
                    }

                    if !model.needsReview.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Needs a look")
                            VStack(spacing: 12) {
                                ForEach(model.needsReview) { item in
                                    ReviewCard(item: item)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }

                    if isClear {
                        AllCaughtUp()
                    }

                    if model.recentlySorted.isEmpty {
                        HowSortingWorks()
                    } else {
                        SortedThisWeek()
                    }

                    if model.sorting.isEmpty && !model.recentlySorted.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionTitle("Recently sorted")
                                Spacer()
                                Button("Show Library") { model.destination = .library }
                                    .buttonStyle(.folioLink)
                            }
                            RecentFilesList(files: Array(model.recentlySorted.prefix(5)))
                        }
                    }

                    FileSources()
                }
                .padding(28)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            // Without the spacer, macOS puts toolbar items at the leading edge, over the title.
            ToolbarSpacer(.flexible)
            ToolbarItem {
                AddFilesButton()
            }
        }
    }
}

/// The current batch: overall progress, then each file and where it went.
private struct SortingProgressCard: View {
    @Environment(AppModel.self) private var model
    let items: [SortingItem]

    private var doneCount: Int {
        items.filter(\.isDone).count
    }

    private var isFinished: Bool {
        doneCount == items.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(isFinished ? "Sorted \(fileCountText(items.count))" : "Sorting \(fileCountText(items.count))")
                    .font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(doneCount) of \(items.count) done")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                if isFinished {
                    Button("Clear") {
                        withAnimation(Theme.motion()) { model.clearFinishedBatch() }
                    }
                    .buttonStyle(.folioLink)
                    .help("Remove this list. Filed files stay in Recently sorted.")
                }
            }

            ProgressBar(fraction: items.isEmpty ? 0 : Double(doneCount) / Double(items.count))

            VStack(spacing: 0) {
                ForEach(items) { item in
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: 1)
                    SortingRow(item: item)
                }
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.1))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .animation(Theme.motion(.easeOut(duration: 0.25)), value: fraction)
            .accessibilityElement()
            .accessibilityLabel("Sorting progress")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

private struct SortingRow: View {
    @Environment(AppModel.self) private var model
    let item: SortingItem

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            switch item.status {
            case .filed(let subjectID, let folder):
                LocationPill(
                    color: model.subject(subjectID)?.color ?? .gray,
                    text: model.location(of: subjectID, folder: folder)
                )
                statusIcon("checkmark.circle", color: Theme.success, label: "Sorted")
            case .reading:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22)
                    .accessibilityLabel("Sorting this file")
            case .needsLook:
                LocationPill(color: Theme.accent, text: String(localized: "Needs a look"))
                statusIcon("questionmark.circle", color: Theme.accentText, label: "Needs a look")
            case .leftAlone:
                Button("Sort Anyway") {
                    model.sortAnyway(item)
                }
                .buttonStyle(.folioLink)
                .help("Choose a subject for it under Needs a look")
                statusIcon("minus.circle", color: Theme.tertiaryText, label: "Left where it was")
            case .duplicate:
                statusIcon("doc.on.doc", color: Theme.tertiaryText, label: "Already filed")
            case .failed:
                statusIcon("exclamationmark.triangle", color: Theme.warning, label: "Couldn't sort")
            }
        }
        .frame(minHeight: 60)
    }

    private func statusIcon(_ systemName: String, color: Color, label: LocalizedStringKey) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17))
            .foregroundStyle(color)
            .frame(width: 22)
            .accessibilityLabel(label)
    }
}

/// Assessments Folio found in files, and files that belong to ones the
/// student already has, each waiting for a yes or no.
struct AssessmentsFound: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AssessmentSuggestion?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Assessments found")
            VStack(spacing: 12) {
                ForEach(model.assessmentSuggestions) { suggestion in
                    AssessmentSuggestionCard(suggestion: suggestion, edit: { editing = suggestion })
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .sheet(item: $editing) { suggestion in
            AssessmentSheet(assessment: model.draft(from: suggestion), isNew: true) { edited in
                model.accept(suggestion, edited: edited)
            }
        }
    }
}

/// A new assessment found in a filed file, or a link from the file to one
/// the student already has.
private struct AssessmentSuggestionCard: View {
    @Environment(AppModel.self) private var model
    let suggestion: AssessmentSuggestion
    let edit: () -> Void

    var body: some View {
        let subject = model.subject(suggestion.subjectID)
        HStack(spacing: 14) {
            IconTile(
                systemName: systemImage,
                foreground: subject?.tintForeground ?? Theme.primaryText,
                background: subject?.tintBackground ?? Color.white.opacity(0.1),
                symbolSize: 15
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(detail(subject: subject))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                if case .new = suggestion.offer {
                    Text("From “\(suggestion.fileName)”")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            Button("Dismiss") { model.dismiss(suggestion) }
                .buttonStyle(.folioLink)
            switch suggestion.offer {
            case .new:
                Button("Edit…", action: edit)
                    .buttonStyle(.folioGhost)
                Button("Add") { model.accept(suggestion) }
                    .buttonStyle(.folioPrimary)
                    .accessibilityLabel("Add Assessment")
            case .link:
                Button("Link") { model.accept(suggestion) }
                    .buttonStyle(.folioPrimary)
                    .accessibilityLabel("Link File")
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
    }

    private var systemImage: String {
        switch suggestion.offer {
        case .new(let found): found.kind.systemImage
        case .link: "link"
        }
    }

    private var title: String {
        switch suggestion.offer {
        case .new(let found):
            return found.title
        case .link(let id, _):
            return String(localized: "Add “\(suggestion.fileName)” to \(model.assessment(id)?.title ?? "")?")
        }
    }

    /// "Task · Biology · Due Fri 14 Nov, 3:00 pm · 30%",
    /// or "Draft · Biology · Mark 18/25" for a link.
    private func detail(subject: Subject?) -> String {
        var parts: [String] = []
        switch suggestion.offer {
        case .new(let found):
            parts.append(String(localized: found.kind.title))
            if let name = subject?.name { parts.append(name) }
            let when = found.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            parts.append(found.kind == .exam || found.kind == .test ? when : String(localized: "Due \(when)"))
            if let weighting = found.weighting { parts.append("\(weighting.formatted())%") }
        case .link(_, let role):
            parts.append(String(localized: role.title))
            if let name = subject?.name { parts.append(name) }
            if let mark = suggestion.mark, let text = Assessment(title: "", subjectID: suggestion.subjectID, due: .now, mark: mark).markText {
                parts.append(String(localized: "Mark \(text)"))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// A file Folio wasn't sure about, with buttons to choose its subject.
private struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    let item: ReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "doc", symbolSize: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.question)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.reasons.isEmpty {
                        Text(item.reasons.prefix(3).joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                if item.url != nil {
                    Button("Skip") {
                        model.skip(item)
                    }
                    .buttonStyle(.folioLink)
                    .help("Leave it where it is")
                }
            }

            FlowLayout(spacing: 10) {
                ForEach(choices) { subject in
                    Button {
                        file(in: subject)
                    } label: {
                        HStack(spacing: 8) {
                            SubjectDot(color: subject.color)
                            Text(subject.name)
                        }
                    }
                    .buttonStyle(.folioChip)
                }
                if !otherSubjects.isEmpty {
                    Menu {
                        ForEach(otherSubjects) { subject in
                            Button(subject.name) { file(in: subject) }
                        }
                    } label: {
                        Text("Other…")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.folioChip)
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
        .contextMenu {
            if let url = item.url {
                Button("Open") { model.open(url) }
                Button("Show in Finder") { model.showInFinder(url) }
            }
        }
    }

    /// The suggested subjects, or every subject when there are no suggestions.
    private var choices: [Subject] {
        let suggested = item.suggestions.compactMap { model.subject($0) }
        return suggested.isEmpty ? model.subjects : suggested
    }

    private var otherSubjects: [Subject] {
        item.suggestions.isEmpty ? [] : model.subjects.filter { !item.suggestions.contains($0.id) }
    }

    private func file(in subject: Subject) {
        withAnimation(Theme.motion()) { model.file(item, in: subject.id) }
    }
}
