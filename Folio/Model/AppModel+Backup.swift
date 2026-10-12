import AppKit
import FolioKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A Folio backup: settings and records, without the files themselves.
    /// The identifier changes with the real bundle ID.
    static let folioBackup = UTType(exportedAs: "io.github.hugh169.folio.backup", conformingTo: .json)
}

extension AppModel {
    // MARK: Backing up

    /// Saves Folio's settings and records into a file the student chooses.
    func backUp() {
        guard let live, let library = libraryURL else { return }
        let panel = NSSavePanel()
        panel.message = String(localized: "Back up Folio's settings and records. Your files stay in your \(libraryTitle), so back that up too.")
        panel.allowedContentTypes = [.folioBackup]
        panel.nameFieldStringValue = String(localized: "Folio Backup \(Date.now.formatted(.iso8601.year().month().day()))", comment: "A backup file's name, with the date")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = FolioBackup(profile: profile, store: live.store, library: library, preferences: backupPreferences())
            try backup.encoded().write(to: url, options: .atomic)
        } catch {
            alert = AlertMessage(title: "Couldn't back up Folio", detail: error.localizedDescription)
        }
    }

    private func backupPreferences() -> FolioBackup.Preferences {
        FolioBackup.Preferences(
            calendars: calendarList
                .filter { plannedCalendarIDs.contains($0.id) || timetableCalendarIDs.contains($0.id) }
                .map { FolioBackup.CalendarChoice(id: $0.id, title: $0.title, account: $0.account, plansAround: plannedCalendarIDs.contains($0.id), isTimetable: timetableCalendarIDs.contains($0.id)) },
            usesReminders: usesReminders,
            watchesDownloads: watchedFolders.contains { $0.isDownloads && $0.isOn },
            watchedFolders: watchedFolders.filter { !$0.isDownloads && $0.isOn }.map(\.path),
            usesOnDeviceAI: usesOnDeviceAI,
            usesClaude: usesClaude,
            claudeSeesPhotos: claudeSeesPhotos
        )
    }

    // MARK: Restoring

    /// Asks for a backup file, then offers to restore it.
    func chooseAndRestoreBackup() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a Folio backup to restore.")
        panel.prompt = String(localized: "Restore", comment: "Button in the panel that chooses a backup")
        panel.allowedContentTypes = [.folioBackup]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openBackup(at: url)
    }

    /// Reads a backup, asks before replacing what's on this Mac, then asks
    /// where the School folder is now.
    func openBackup(at url: URL) {
        let backup: FolioBackup
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            backup = try FolioBackup.decode(Data(contentsOf: url))
        } catch FolioBackup.BackupError.newerVersion {
            alert = AlertMessage(title: "This backup is from a newer Folio", message: "Update Folio, then restore it.")
            return
        } catch {
            alert = AlertMessage(title: "Couldn't open the backup", message: "It isn't a Folio backup, or it's damaged.")
            return
        }

        let confirm = NSAlert()
        confirm.messageText = String(localized: "Restore Folio from this backup?")
        let made = backup.createdAt.formatted(date: .long, time: .shortened)
        let contents = [
            String(localized: "\(backup.profile.sortableSubjects.count) subjects"),
            String(localized: "\(backup.filed.count) filed files"),
        ]
        var lines = [String(localized: "It was made on \(made), with \(contents.formatted(.list(type: .and))).")]
        if phase == .ready {
            lines.append(String(localized: "It replaces Folio's settings and records on this Mac. Your files aren't moved or changed."))
        }
        lines.append(backup.profile.level == .university
            ? String(localized: "Next, choose your Uni folder: the one with your course folders in it.")
            : String(localized: "Next, choose your School folder: the one with your subject folders in it."))
        confirm.informativeText = lines.joined(separator: "\n\n")
        confirm.addButton(withTitle: String(localized: "Choose Folder…"))
        confirm.addButton(withTitle: String(localized: "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the folder with your subject folders in it.")
        panel.prompt = String(localized: "Restore Here", comment: "Button in the panel that chooses where the School folder is")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = HomeFolderPanel.home.appending(path: "Documents", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let library = panel.url else { return }
        restore(backup, library: library)
    }

    /// Replaces Folio's settings and records with the backup's, sorting into
    /// `library` from now on.
    func restore(_ backup: FolioBackup, library: URL) {
        guard let live else { return }
        do {
            live.listener?.cancel()
            live.librarian?.shutDown()
            live.librarian = nil
            let link = live.calendarLink
            let restored = try backup.restore(
                into: live.store,
                library: library,
                fileExists: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) },
                reminderExists: { id in
                    guard let link, link.canUseReminders else { return true }
                    return link.reminderExists(id: id)
                }
            )
            try live.bookmarks.saveLibrary(library)
            try live.profileStore.save(backup.profile)
            profile = backup.profile

            var notes: [String] = []
            usesOnDeviceAI = backup.preferences.usesOnDeviceAI
            setClaudeSeesPhotos(backup.preferences.claudeSeesPhotos)
            if backup.preferences.usesClaude {
                notes.append(String(localized: "To use Claude again, turn it on in Settings › AI & Privacy. Its key isn't kept in backups."))
            }
            if !backup.preferences.calendars.isEmpty, !restoreCalendarChoices(backup.preferences.calendars) {
                notes.append(String(localized: "Connect Apple Calendar in Settings › Planner to plan around your calendar again."))
            }
            if backup.preferences.usesReminders, !restoreUsesReminders(true) {
                notes.append(String(localized: "Turn on Reminders again in Settings › Planner."))
            }
            if backup.preferences.watchesDownloads, let downloads = watchedFolders.first(where: \.isDownloads), !downloads.isOn {
                setWatching(downloads, on: true)
            }
            let others = backup.preferences.watchedFolders.map { URL(filePath: $0).lastPathComponent }
            if !others.isEmpty {
                notes.append(String(localized: "Folio was also watching \(others.formatted(.list(type: .and))). Turn watching on again in Settings › Background."))
            }

            loadPlanner()
            loadStudy()
            needsLibraryAgain = false
            open(library: library)
            phase = .ready
            destination = .library

            var parts = [
                String(localized: "\(profile.sortableSubjects.count) subjects"),
                String(localized: "\(restored.filed) filed files"),
                String(localized: "\(restored.assessments) assessments"),
                String(localized: "\(restored.sessions) study sessions"),
            ]
            if restored.todos > 0 {
                parts.append(String(localized: "\(restored.todos) to-dos"))
            }
            if restored.flashcards > 0 {
                parts.append(String(localized: "\(restored.flashcards) flashcards"))
            }
            var summary = [String(localized: "Restored \(parts.formatted(.list(type: .and))).")]
            if restored.waitingNotFound > 0 {
                summary.append(String(localized: "\(restored.waitingNotFound) files waiting under Needs a look weren't where they were before, so they're not listed."))
            }
            alert = AlertMessage(title: "Folio is restored", detail: (summary + notes).joined(separator: "\n\n"))
        } catch {
            alert = AlertMessage(title: "Couldn't restore the backup", detail: error.localizedDescription)
            if let library = libraryURL { open(library: library) }
        }
    }

}
