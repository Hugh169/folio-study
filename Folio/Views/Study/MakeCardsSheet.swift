import SwiftUI
import FolioKit

/// Writes flashcards from one of the student's files: choose the file, let
/// the on-device AI (or Claude, when the student saved a key) write questions
/// from it, then keep the ones they want, changing any first.
struct MakeCardsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Stage {
        case choosing
        case writing(String)
        case choosingCards(CardWriting)
    }

    @State private var subjectID: Subject.ID?
    @State private var file: URL?
    @State private var filter = ""
    @State private var withClaude = false
    /// Students with a Claude key write with Claude until they choose the Mac instead.
    @AppStorage("writesCardsWithClaude") private var prefersClaude = true
    @State private var stage: Stage = .choosing
    @State private var drafts: [CardDraft] = []
    @State private var keeping: Set<CardDraft.ID> = []
    @State private var task: Task<Void, Never>?
    @State private var looksLikeQuestions = false

    /// - Parameter written: Cards already written, to start at choosing them, for screenshots.
    init(subjectID: Subject.ID? = nil, file: URL? = nil, written: CardWriting? = nil) {
        _subjectID = State(initialValue: subjectID)
        _file = State(initialValue: file)
        if let written {
            _stage = State(initialValue: .choosingCards(written))
            _drafts = State(initialValue: written.drafts)
            _keeping = State(initialValue: Set(written.drafts.dropLast().map(\.id)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Make Flashcards")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Rectangle().fill(Theme.separator).frame(height: 1)
            switch stage {
            case .choosing: choosing
            case .writing(let message): writing(message)
            case .choosingCards(let writing): choosingCards(writing)
            }
        }
        .frame(width: 620, height: 560)
        .background(Theme.windowBackground)
        .onAppear {
            if subjectID == nil, let file {
                subjectID = model.libraryFile(at: file)?.subjectID
            }
            subjectID = subjectID ?? model.subjects.first?.id
            withClaude = model.hasClaudeKey && prefersClaude
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: Choosing a file

    /// A file in the list, chosen by where it is. The library's own IDs are
    /// new each time it refreshes, and the list only selects rows whose tag
    /// is a `URL`, not a `URL?`.
    private struct Choice: Identifiable {
        let file: SortedFile
        let url: URL
        var id: URL { url }
    }

    private var files: [Choice] {
        guard let subjectID else { return [] }
        // Files Folio already knows are for an assessment aren't offered: it won't make cards from them.
        let linked = model.assessmentSheetPaths()
        let all = model.libraryFiles
            .filter { $0.subjectID == subjectID }
            .sorted { $0.sortedAt > $1.sortedAt }
            .compactMap { file in file.url.map { Choice(file: file, url: $0) } }
            .filter { !model.isAssessmentFile($0.url, folder: $0.file.folder, linked: linked) }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.file.name.localizedStandardContains(filter) }
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker("Subject", selection: $subjectID) {
                    ForEach(model.subjects) { subject in
                        Text(verbatim: subject.name).tag(Optional(subject.id))
                    }
                }
                .frame(maxWidth: 240)
                TextField("Filter files", text: $filter)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.top, 16)

            Text("Cards work best from notes, slides and recordings of lessons. Folio never uses task sheets.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)

            List(files, selection: $file) { choice in
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .foregroundStyle(Theme.secondaryText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.file.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.location(of: choice.file.subjectID, folder: choice.file.folder))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .tag(choice.url)
            }
            .onChange(of: subjectID) { previous, _ in
                // Switching subject unchooses a file from the last one, so its
                // cards can't land in the wrong subject.
                if previous != nil, let file, !files.contains(where: { $0.url == file }) { self.file = nil }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .overlay {
                if files.isEmpty {
                    Text(filter.isEmpty ? "No files in this subject yet." : "No files match.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            if model.hasClaudeKey {
                Picker("Write with", selection: $withClaude) {
                    Text("On this Mac").tag(false)
                    Text("Claude").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: withClaude) { prefersClaude = withClaude }
                .shotTarget("write-with")
                Text(withClaude
                     ? "Claude reads all of the file and writes a card for each important idea. It sends the file's text to Anthropic with your key: usually well under a US cent a file."
                     : "The on-device AI writes up to 24 cards. Nothing leaves your Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let file, case let made = model.cards(madeFrom: file, sourceID: nil).count, made > 0 {
                Text("You have \(made) cards from this file already. Folio leaves out any repeats.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Write Cards") { write(anyway: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || subjectID == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    // MARK: Writing

    private func writing(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("You can keep working. Long files take a minute or two.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    stage = .choosing
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private func write(anyway: Bool) {
        guard let file, let subjectID else { return }
        stage = .writing(String(localized: "Reading “\(file.lastPathComponent)”…"))
        task = Task {
            let result = await model.writeCards(from: file, subjectID: subjectID, withClaude: withClaude, anyway: anyway) { message in
                if case .writing = stage { stage = .writing(message) }
            }
            guard !Task.isCancelled else { return }
            drafts = result.drafts
            keeping = Set(result.drafts.map(\.id))
            looksLikeQuestions = result.isMostlyQuestions
            stage = .choosingCards(result)
        }
    }

    // MARK: Choosing cards

    private func choosingCards(_ writing: CardWriting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if drafts.isEmpty {
                Spacer()
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemName: "exclamationmark.bubble", foreground: Theme.warning, background: Theme.warning.opacity(0.16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No cards from “\(writing.sourceName)”")
                            .font(.system(size: 14, weight: .semibold))
                        Text(writing.message ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if looksLikeQuestions {
                            Button("Try Anyway") { write(anyway: true) }
                                .buttonStyle(.folioGhost)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 20)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Cards from “\(writing.sourceName)”")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if drafts.count > 8 {
                            Button(keeping.count == drafts.count ? "Untick All" : "Tick All") {
                                keeping = keeping.count == drafts.count ? [] : Set(drafts.map(\.id))
                            }
                            .buttonStyle(.folioLink)
                        }
                    }
                    Text(writing.dropped > 0
                         ? String(localized: "Untick any you don't want, or change their words. Folio left out \(writing.dropped) whose answers weren't in the file.")
                         : String(localized: "Untick any you don't want, or change their words."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                    if let note = writing.note {
                        Text(verbatim: note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($drafts) { $draft in
                            DraftRow(draft: $draft, isKept: Binding(
                                get: { keeping.contains(draft.id) },
                                set: { if $0 { keeping.insert(draft.id) } else { keeping.remove(draft.id) } }
                            ))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Button("Back") {
                    stage = .choosing
                    drafts = []
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !drafts.isEmpty {
                    Button("Add \(keeping.count) Cards") {
                        guard let subjectID else { return }
                        model.keep(drafts.filter { keeping.contains($0.id) }, from: writing, subjectID: subjectID)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(keeping.isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }
}

/// A written card with a tick to keep it, and its words to change.
private struct DraftRow: View {
    @Binding var draft: CardDraft
    @Binding var isKept: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Keep", isOn: $isKept)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Question", text: $draft.question, axis: .vertical)
                    .font(.system(size: 13.5, weight: .semibold))
                    .textFieldStyle(.plain)
                TextField("Answer", text: $draft.answer, axis: .vertical)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                if let quote = draft.quote {
                    Text("“\(quote)”")
                        .font(.system(size: 11.5).italic())
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(Theme.cardBackground))
        .opacity(isKept ? 1 : 0.55)
    }
}
