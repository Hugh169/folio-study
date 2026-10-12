import SwiftUI
import FolioKit

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// Files whose text matches the search, from the search index.
    @State private var hits: [SearchHit] = []

    /// - Parameters: A search already typed and its results, for screenshots.
    init(query: String = "", hits: [SearchHit] = []) {
        _query = State(initialValue: query)
        _hits = State(initialValue: hits)
    }

    var body: some View {
        Screen(title: "Library") {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if query.isEmpty {
                        if let greeting = model.greeting {
                            Text(greeting)
                                .font(.system(size: 24, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let notice = model.aiNotice {
                            NoticeBanner(systemImage: "apple.intelligence", text: notice)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            DropZone()
                            if let progress = model.learningProgress {
                                LearningProgressLine(done: progress.done, total: progress.total)
                            }
                        }
                    }

                    if query.isEmpty {
                        if !recentFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle("Recently sorted")
                                RecentFilesList(files: recentFiles)
                            }
                        }
                    } else if !results.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Files")
                            RecentFilesList(files: results.map(\.file), matches: Dictionary(results.map { ($0.file.id, $0.matched) }, uniquingKeysWith: { first, _ in first }))
                        }
                    }
                    if !query.isEmpty, let progress = model.indexingProgress, progress.total > 0 {
                        Text("Reading your files so search can find what's in them… \(progress.done) of \(progress.total)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                            .monospacedDigit()
                            .padding(.leading, 4)
                    }

                    if !matchingSubjects.isEmpty || query.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(verbatim: model.subjectsTitle)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                                ForEach(matchingSubjects) { subject in
                                    FolderCard(
                                        title: subject.name,
                                        subtitle: fileCountText(model.fileCount(of: subject.id)),
                                        foreground: subject.tintForeground,
                                        background: subject.tintBackground
                                    ) {
                                        model.destination = .subject(subject.id)
                                    }
                                }
                                if query.isEmpty {
                                    NewSubjectCard { model.isAddingSubject = true }
                                }
                            }
                        }
                    }

                    if query.isEmpty && !model.archivedSubjects.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Past terms")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                                ForEach(model.archivedSubjects) { subject in
                                    FolderCard(
                                        title: subject.name,
                                        subtitle: [subject.term, fileCountText(model.fileCount(of: subject.id))].compactMap { $0 }.joined(separator: " · "),
                                        foreground: Theme.secondaryText,
                                        background: Color.white.opacity(0.06)
                                    ) {
                                        model.destination = .subject(subject.id)
                                    }
                                }
                            }
                        }
                    }

                    if !query.isEmpty && results.isEmpty && matchingSubjects.isEmpty {
                        Text("No results for “\(query)”")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(28)
            }
        }
        // macOS always puts a flexible gap before the search field, so "Add Files"
        // can't sit beside it; the drop zone's Choose Files… and ⌘O cover it.
        .searchable(text: $query, placement: .toolbar, prompt: "Search names and what's in files")
        .task(id: query) {
            // Wait for a pause in typing before searching inside files.
            guard !query.isEmpty else {
                hits = []
                return
            }
            guard model.librarySearch != nil else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hits = await model.searchFiles(query)
        }
        .toolbar {
            // Without the spacer, the search field sits at the leading edge, over the title.
            ToolbarSpacer(.flexible)
            DefaultToolbarItem(kind: .search)
        }
    }

    /// Files found by what's in them, then files found only by name.
    private var results: [SearchHit] {
        let found = Set(hits.compactMap { $0.file.url?.standardizedFileURL.path(percentEncoded: false) })
        let byName = recentFiles.filter { !found.contains($0.url?.standardizedFileURL.path(percentEncoded: false) ?? "") }
        return Array((hits + byName.map { SearchHit(file: $0, matched: []) }).prefix(50))
    }

    /// The latest filed files, or files whose names match the search: Folio's
    /// own first, then anything else in the library.
    private var recentFiles: [SortedFile] {
        guard !query.isEmpty else { return Array(model.recentlySorted.prefix(5)) }
        let filed = model.recentlySorted.filter { $0.name.localizedStandardContains(query) }
        let filedPaths = Set(filed.compactMap { $0.url?.standardizedFileURL.path })
        let others = model.libraryFiles
            .filter { $0.name.localizedStandardContains(query) && !filedPaths.contains($0.url?.standardizedFileURL.path ?? "") }
            .sorted { $0.sortedAt > $1.sortedAt }
        return Array((filed + others).prefix(50))
    }

    private var matchingSubjects: [Subject] {
        guard !query.isEmpty else { return model.subjects }
        return model.subjects.filter { $0.name.localizedStandardContains(query) }
    }
}

/// The dashed area at the top of the Library and the Inbox. Dropped files
/// go to the Inbox.
struct DropZone: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 18) {
            IconTile(
                systemName: "arrow.down.to.line",
                foreground: Theme.accent,
                background: Theme.accent.opacity(0.16),
                size: 56,
                cornerRadius: 16,
                symbolSize: 22
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop schoolwork here")
                    .font(.system(size: 17, weight: .semibold))
                Text("PDFs, photos, documents and slides are read and filed by subject.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Choose Files…") { model.isImporting = true }
                .buttonStyle(.folioGhost)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .fill(isTargeted ? Theme.accent.opacity(0.08) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(
                    isTargeted ? Theme.accent : Color.white.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
        .animation(Theme.motion(.easeOut(duration: 0.15)), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
        }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active: isTargeted = true
            default: isTargeted = false
            }
        }
    }
}

/// The card listing recently sorted files, each with an Undo link.
struct RecentFilesList: View {
    let files: [SortedFile]
    /// The search's words found in each file, when these are search results.
    var matches: [SortedFile.ID: [String]] = [:]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                ForEach(files) { file in
                    RecentFileRow(file: file, now: context.date, matched: matches[file.id] ?? [])
                    if file.id != files.last?.id {
                        Rectangle()
                            .fill(Theme.separator)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        }
    }
}

private struct RecentFileRow: View {
    @Environment(AppModel.self) private var model
    let file: SortedFile
    let now: Date
    var matched: [String] = []
    @State private var sheet: FileSheet?

    /// Only files Folio filed can be put back.
    private var canUndo: Bool {
        model.recentlySorted.contains { $0.id == file.id }
    }

    var body: some View {
        let subject = model.subject(file.subjectID)
        HStack(spacing: 14) {
            IconTile(
                systemName: "doc",
                foreground: subject?.tintForeground ?? Theme.primaryText,
                background: subject?.tintBackground ?? Color.white.opacity(0.1),
                symbolSize: 15
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(matched.isEmpty
                     ? model.location(of: file.subjectID, folder: file.folder)
                     : "\(model.location(of: file.subjectID, folder: file.folder)) · \(String(localized: "Found \(matched.prefix(3).map { "“\($0)”" }.joined(separator: ", "))"))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(relativeTime)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
            if canUndo {
                Button("Undo") {
                    withAnimation(Theme.motion()) { model.undo(file) }
                }
                .buttonStyle(.folioLink)
                .help("Put this file back where it was and choose another subject")
            }
        }
        .frame(height: 62)
        .contentShape(Rectangle())
        .contextMenu {
            if let url = file.url {
                Button("Open") { model.open(url) }
                Button("Show in Finder") { model.showInFinder(url) }
                Divider()
                FileStudyMenuItems(file: file, sheet: $sheet)
            }
        }
        .fileSheets($sheet)
    }

    private var relativeTime: String {
        if now.timeIntervalSince(file.sortedAt) < 60 { return String(localized: "Just now") }
        let style = Date.RelativeFormatStyle(
            presentation: .named,
            unitsStyle: .abbreviated,
            capitalizationContext: .beginningOfSentence
        )
        return file.sortedAt.formatted(style)
    }
}

/// "Learning from files you've already sorted… 12 of 40", under the drop zone.
private struct LearningProgressLine: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text(total == 0 ? "Looking at the files already in your subject folders…" : "Learning from files you've already sorted… \(done) of \(total)")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct NewSubjectCard: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                IconTile(systemName: "plus", background: Color.white.opacity(0.08), symbolSize: 15)
                Spacer(minLength: 0)
                Text(model.newSubjectTitle)
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: FolderCard.minHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(isHovered ? Color.white.opacity(0.03) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
