import AppIntents
import UniformTypeIdentifiers

/// Shortcuts action: sort the files it's given, as if they'd been dropped on
/// Folio, and say what happened.
struct SortFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Sort Files"
    static let description = IntentDescription("Reads each file and files it in the right subject folder. Anything Folio isn't sure about waits in its Inbox.")

    @Parameter(title: "Files", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Dependency private var model: AppModel

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty else {
            return .result(dialog: "Folio can only sort files saved on this Mac.")
        }
        let summary = await model.sortForShortcut(urls)
        return .result(dialog: "\(summary)")
    }
}

/// Shortcuts action: sort every file in a folder.
struct SortFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Sort Folder"
    static let description = IntentDescription("Sorts every file in a folder into your subject folders. Files that aren't schoolwork stay where they are.")

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile

    @Dependency private var model: AppModel

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = folder.fileURL else {
            return .result(dialog: "Folio can only sort folders saved on this Mac.")
        }
        let summary = await model.sortForShortcut([url])
        return .result(dialog: "\(summary)")
    }
}

struct FolioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SortFilesIntent(),
            phrases: ["Sort files with \(.applicationName)"],
            shortTitle: "Sort Files",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
