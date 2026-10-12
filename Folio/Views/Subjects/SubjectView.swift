import SwiftUI
import FolioKit

/// One subject at a glance: its next class and teachers, what's due, its
/// flashcards, its to-dos, its assessments and marks, its past papers to
/// practise, its folders, and what was sorted into it lately.
struct SubjectView: View {
    @Environment(AppModel.self) private var model
    let subject: Subject
    @State private var editing: Assessment?
    @State private var isAdding = false

    var body: some View {
        Screen(verbatimTitle: subject.name, subtitle: subtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // The three cards as tall as the tallest.
                    HStack(alignment: .top, spacing: 14) {
                        nextClassCard
                        nextDueCard
                        SubjectCardsCard(subject: subject)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("To do")
                        TodoList(subjectID: subject.id)
                    }

                    assessmentsSection

                    SubjectProgressSection(subject: subject)

                    PastPapersSection(subject: subject)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Folders")
                        if model.folders(of: subject.id).isEmpty {
                            Text("Nothing here yet. Files you file under \(subject.name) will appear here.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.leading, 4)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                                ForEach(model.folders(of: subject.id)) { folder in
                                    FolderCard(
                                        title: folder.name,
                                        subtitle: fileCountText(folder.fileCount),
                                        foreground: subject.tintForeground,
                                        background: subject.tintBackground,
                                        action: folder.url.map { url in { model.open(url) } }
                                    )
                                    .help(folder.url == nil ? "" : "Open in Finder")
                                }
                            }
                        }
                    }

                    if !recentFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Recently sorted")
                            RecentFilesList(files: recentFiles)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button {
                    isAdding = true
                } label: {
                    Label("New Assessment", systemImage: "plus")
                }
                .help("Add an assessment for \(subject.name)")
            }
            if let folder = model.subjectFolderURLs[subject.id] {
                ToolbarItem {
                    Button {
                        model.open(folder)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Open the \(subject.name) folder in Finder")
                }
            }
            ToolbarItem {
                AddFilesButton()
            }
        }
        .sheet(item: $editing) { assessment in
            AssessmentSheet(assessment: assessment)
        }
        .sheet(isPresented: $isAdding) {
            AssessmentSheet(assessment: Assessment(title: "", subjectID: subject.id, due: .now), isNew: true)
        }
    }

    /// "42 files · Ms Nguyen".
    private var subtitle: String {
        ([fileCountText(model.fileCount(of: subject.id))] + subject.teachers).joined(separator: " · ")
    }

    private var recentFiles: [SortedFile] {
        model.recentlySorted.filter { $0.subjectID == subject.id }
    }

    private var upcoming: [Assessment] {
        model.assessments(of: subject.id).filter { !$0.isDone }
    }

    private var past: [Assessment] {
        model.assessments(of: subject.id).filter(\.isDone).sorted { $0.due > $1.due }
    }

    private var nextClassCard: some View {
        HubCard(title: "Next class", systemImage: "clock", subject: subject) {
            if let lesson = model.nextClass(of: subject.id) {
                Text(lessonDay(lesson))
                    .font(.system(size: 15, weight: .semibold))
                Text((lesson.start..<lesson.end).formatted(.interval.hour().minute()))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text(model.profile.timetable == nil && model.timetableCalendarIDs.isEmpty ? "Add your timetable in Settings › Planner." : "None in the next three weeks.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var nextDueCard: some View {
        HubCard(title: "Next due", systemImage: "calendar", subject: subject) {
            if let next = upcoming.first {
                Text(next.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text([model.countdown(to: next.due), next.weightingText].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("Nothing due.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// "Today", "Tomorrow" or "Thursday 15 October".
    private func lessonDay(_ lesson: ClassSession) -> String {
        if model.calendar.isDateInToday(lesson.start) { return String(localized: "Today") }
        if model.calendar.isDateInTomorrow(lesson.start) { return String(localized: "Tomorrow") }
        return lesson.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    @ViewBuilder private var assessmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Assessments")
            if upcoming.isEmpty && past.isEmpty {
                Text("No assessments yet. Add one with the + button, or drop a task sheet on Folio.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 4)
            } else {
                VStack(spacing: 0) {
                    let all = upcoming + past
                    ForEach(all) { assessment in
                        AssessmentRow(assessment: assessment)
                            .padding(.horizontal, 16)
                            .assessmentActions(assessment, edit: { editing = assessment })
                        if assessment.id != all.last?.id {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 1)
                                .padding(.leading, 60)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
        }
    }
}

/// A small card on a subject's page, such as its next class.
private struct HubCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let subject: Subject
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(subject.tintForeground)
                .textCase(.uppercase)
                .padding(.bottom, 4)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(subject.color.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}
