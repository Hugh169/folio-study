import AppKit
import FolioKit
import ServiceManagement
import UserNotifications

/// What Delete All Data did, for the end of the sheet.
struct DeletionReport {
    var removedReminders = 0
    var removedRemindersList = false
    /// Things Folio couldn't remove, in words for the student.
    var problems: [String] = []
}

/// Runs when Folio quits after Delete All Data, to remove the settings AppKit
/// saves on the way out, such as where the window was.
enum DeletedEverything {
    nonisolated(unsafe) static var cleanUpAtQuit: (() -> Void)?
}

extension AppModel {
    /// Deletes everything Folio keeps, as if it had never been installed: its
    /// records, settings and what it learned, the Claude key in the keychain,
    /// its notifications and Open at Login, and, when `removingReminders`, the
    /// reminders it added. The student's files stay where they are. Nothing is
    /// saved afterwards, and Folio quits once the student has read what happened.
    func deleteAllData(removingReminders: Bool) async -> DeletionReport {
        var report = DeletionReport()
        guard let live else { return report }

        // Stop everything that reads files or saves: sorting, watching, searching, the timer.
        focusTimer?.cancel()
        indexTask?.cancel()
        for task in [live.listener, live.saveTask, live.refreshTask, live.learningTask, live.watchListener, live.heartbeat, live.notifyTask] {
            task?.cancel()
        }
        await live.watcher.stop()
        live.librarian?.shutDown()
        live.librarian = nil

        if live.ownsSystemItems {
            if removingReminders, usesReminders, let link = live.calendarLink, link.canUseReminders {
                let removed = await link.removeFolioReminders(ids: live.store.assessmentRecords().compactMap(\.reminderID))
                report.removedReminders = removed.reminders
                report.removedRemindersList = removed.list
            }
            let notifications = UNUserNotificationCenter.current()
            notifications.removeAllPendingNotificationRequests()
            notifications.removeAllDeliveredNotifications()
            if SMAppService.mainApp.status == .enabled {
                do {
                    try await SMAppService.mainApp.unregister()
                } catch {
                    report.problems.append(String(localized: "Folio couldn't stop opening at login. Turn it off in System Settings › General › Login Items."))
                }
            }
            Self.removeCaches()
        }
        if let keychain = live.keychain, keychain.hasPassword {
            do {
                try keychain.delete()
            } catch {
                report.problems.append(String(localized: "Your Claude key couldn't be removed from the keychain. Delete “\(keychain.label)” in Keychain Access."))
            }
        }

        // Let go of the records before deleting them, so nothing writes them again.
        let supportFolder = live.supportFolder
        let defaults = live.defaults
        let defaultsName = live.defaultsName
        self.live = nil
        do {
            try FileManager.default.removeItem(at: supportFolder)
        } catch CocoaError.fileNoSuchFile {
            // Nothing saved yet.
        } catch {
            report.problems.append(String(localized: "Some of Folio's records couldn't be deleted: \(error.localizedDescription)"))
        }
        if let defaultsName {
            defaults.removePersistentDomain(forName: defaultsName)
            DeletedEverything.cleanUpAtQuit = { defaults.removePersistentDomain(forName: defaultsName) }
        }

        // Nothing in memory can be saved again, so show nothing that could be changed.
        hasDeletedEverything = true
        focus = nil
        flashcards = []
        todos = []
        sessions = []
        assessments = []
        practiceAttempts = []
        needsReview = []
        recentlySorted = []
        sorting = []
        libraryFiles = []
        hasClaudeKey = false
        usesClaude = false
        return report
    }

    /// Empties Folio's caches, such as the replies URLSession kept. In the
    /// sandbox they're all Folio's; otherwise only its own folder is touched.
    private static func removeCaches() {
        let manager = FileManager.default
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let bundleID = Bundle.main.bundleIdentifier ?? "Folio"
        var items: [URL] = []
        if isSandboxed {
            items += (try? manager.contentsOfDirectory(at: .cachesDirectory, includingPropertiesForKeys: nil)) ?? []
            items += (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        } else {
            items.append(URL.cachesDirectory.appending(path: bundleID, directoryHint: .isDirectory))
        }
        items.append(URL.libraryDirectory.appending(path: "HTTPStorages/\(bundleID)", directoryHint: .isDirectory))
        items.append(URL.libraryDirectory.appending(path: "HTTPStorages/\(bundleID).binarycookies"))
        for item in items {
            try? manager.removeItem(at: item)
        }
    }

    /// Quits Folio after Delete All Data, first showing it in Finder if the
    /// student wants to remove it too.
    func quitAfterDeletingEverything(showingInFinder: Bool) {
        let app = Bundle.main.bundleURL
        // A copy run straight from a download is in a read-only place macOS made up, not worth showing.
        guard showingInFinder, !app.path(percentEncoded: false).contains("/AppTranslocation/") else {
            NSApp.terminate(nil)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([app])
        // Give Finder a moment to take the request before Folio goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}
