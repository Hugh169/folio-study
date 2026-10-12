import SwiftUI
import FolioKit

/// What a file can open from its menu: what it's about, files like it, or
/// flashcards from it.
enum FileSheet: Identifiable {
    case whatsThis(SortedFile)
    case related(SortedFile)
    case makeCards(SortedFile)

    var id: String {
        switch self {
        case .whatsThis(let file): "whatsThis-\(file.id)"
        case .related(let file): "related-\(file.id)"
        case .makeCards(let file): "makeCards-\(file.id)"
        }
    }
}

extension View {
    /// The sheets a file's menu opens.
    func fileSheets(_ sheet: Binding<FileSheet?>) -> some View {
        self.sheet(item: sheet) { sheet in
            switch sheet {
            case .whatsThis(let file): WhatsThisSheet(file: file)
            case .related(let file): RelatedFilesSheet(file: file)
            case .makeCards(let file): MakeCardsSheet(subjectID: file.subjectID, file: file.url)
            }
        }
    }
}

/// The study items in a file's menu.
struct FileStudyMenuItems: View {
    let file: SortedFile
    @Binding var sheet: FileSheet?

    var body: some View {
        if file.url != nil {
            Button("What's This?") { sheet = .whatsThis(file) }
            Button("Related Files") { sheet = .related(file) }
            Button("Make Flashcards…") { sheet = .makeCards(file) }
        }
    }
}

/// A file's main points, from the on-device AI.
struct WhatsThisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: SortedFile

    @State private var progress = ""
    @State private var points: [String] = []
    @State private var problem: String?
    @State private var isMakingCards = false

    /// - Parameter points: Points already written, for screenshots.
    init(file: SortedFile, points: [String] = []) {
        self.file = file
        _points = State(initialValue: points)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: "sparkles", foreground: Theme.purple, background: Theme.purple.opacity(0.16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's this?")
                        .font(.system(size: 15, weight: .semibold))
                    Text(file.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Group {
                if let problem {
                    Text(problem)
                        .foregroundStyle(Theme.secondaryText)
                } else if points.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progress)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Theme.purple).frame(width: 5, height: 5).offset(y: -2)
                                Text(point)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        Text("Written on this Mac by the on-device AI, from the start of the file. Check anything important in the file itself.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.top, 4)
                    }
                }
            }
            .font(.system(size: 13.5))
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)

            HStack {
                Button("Make Flashcards…") { isMakingCards = true }
                    .disabled(points.isEmpty)
                Spacer()
                Button("Open") { model.open(file.url) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            guard points.isEmpty, let url = file.url else { return }
            switch await model.summary(of: url, progress: { progress = $0 }) {
            case .success(let found): points = found
            case .failure(let failure): problem = failure.message
            }
        }
        .sheet(isPresented: $isMakingCards) {
            MakeCardsSheet(subjectID: file.subjectID, file: file.url)
        }
    }
}

/// Files on the same topic as one file, from any subject.
struct RelatedFilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: SortedFile

    var body: some View {
        let related = file.url.map { model.relatedFiles(to: $0) } ?? []
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Related files")
                    .font(.system(size: 15, weight: .semibold))
                Text("Like “\(file.name)”")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if related.isEmpty {
                Text(model.librarySearch == nil || model.indexingProgress != nil
                     ? "Folio is still reading your files. Try again in a minute."
                     : "Nothing else in your library is much like this file.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    ForEach(related) { other in
                        HStack(spacing: 10) {
                            SubjectDot(color: model.subject(other.subjectID)?.color ?? .gray)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(other.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(model.location(of: other.subjectID, folder: other.folder))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 8)
                            Button("Open") { model.open(other.url) }
                                .buttonStyle(.folioLink)
                        }
                        .padding(.vertical, 8)
                        if other.id != related.last?.id {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
