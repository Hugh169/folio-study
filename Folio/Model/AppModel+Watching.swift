import AppKit
import FolioKit
import ServiceManagement
import SwiftUI

/// A folder Folio watches for new files.
struct WatchedFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    /// How Folio gets back into the folder after a restart. Downloads doesn't
    /// need one: Folio's Downloads entitlement covers it.
    var bookmark: Data?
    var isOn: Bool

    var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
    var isDownloads: Bool { bookmark == nil }
    /// The name to show: Downloads in the student's language, or the folder's own name.
    var displayName: String { isDownloads ? String(localized: "Downloads") : name }

    /// The real Downloads folder. Inside the sandbox the usual APIs give Folio's
    /// own container instead.
    static var downloads: WatchedFolder {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return WatchedFolder(name: "Downloads", path: home + "/Downloads", bookmark: nil, isOn: false)
    }
}

/// How a file sorted in the background ended up, for Shortcuts.
enum BackgroundOutcome {
    case filed(name: String, location: String)
    case needsALook(name: String)
    case leftAlone(name: String)
    case duplicate(name: String)
    case failed(name: String, message: String)
}

extension AppModel {
    private static let watchedFoldersKey = "watchedFolders"
    private static let watchingSeenKey = "watchingSeenAt"

    // MARK: Watched folders

    func loadWatchedFolders() {
        guard let live else { return }
        if let data = live.defaults.data(forKey: Self.watchedFoldersKey),
           let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            watchedFolders = folders
        } else {
            watchedFolders = [.downloads]
        }
    }

    private func saveWatchedFolders() {
        guard let live, let data = try? JSONEncoder().encode(watchedFolders) else { return }
        live.defaults.set(data, forKey: Self.watchedFoldersKey)
    }

    /// Turns watching a folder on or off.
    func setWatching(_ folder: WatchedFolder, on isOn: Bool) {
        guard let index = watchedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        watchedFolders[index].isOn = isOn
        saveWatchedFolders()
        if isOn {
            askForNotificationsOnce()
        }
        Task { await startWatching(since: nil) }
    }

    /// Asks for a folder to watch, such as a school Google Drive folder.
    func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a folder for Folio to watch. New files that arrive in it are sorted.")
        panel.prompt = String(localized: "Watch Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addWatchedFolder(url) }
    }

    /// Starts watching a folder Folio has access to.
    func addWatchedFolder(_ url: URL) async {
        guard !watchedFolders.contains(where: { $0.path == url.path(percentEncoded: false) }),
              let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        else { return }
        if live?.openedWatchedFolders.insert(url.path(percentEncoded: false)).inserted == true {
            _ = url.startAccessingSecurityScopedResource()
        }
        watchedFolders.append(WatchedFolder(name: url.lastPathComponent, path: url.path(percentEncoded: false), bookmark: bookmark, isOn: true))
        saveWatchedFolders()
        askForNotificationsOnce()
        await startWatching(since: nil)
    }

    func removeWatchedFolder(_ folder: WatchedFolder) {
        watchedFolders.removeAll { $0.id == folder.id }
        saveWatchedFolders()
        Task { await startWatching(since: nil) }
    }

    func setWatchingPaused(_ paused: Bool) {
        isWatchingPaused = paused
        // Files that arrive while paused are left alone.
        Task { await startWatching(since: nil) }
    }

    /// Watches every folder that's on. Files added since `since` are sorted
    /// too, which covers downloads made while Folio wasn't running.
    func startWatching(since: Date?) async {
        guard let live else { return }
        var folders: [URL: Date?] = [:]
        if !isWatchingPaused && phase == .ready {
            for folder in watchedFolders where folder.isOn {
                if let bookmark = folder.bookmark {
                    var isStale = false
                    guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else { continue }
                    if live.openedWatchedFolders.insert(url.path(percentEncoded: false)).inserted {
                        _ = url.startAccessingSecurityScopedResource()
                    }
                    folders[url] = since
                } else {
                    folders[folder.url] = since
                }
            }
        }
        await live.watcher.watch(folders)
        if live.watchListener == nil {
            let arrivals = live.watcher.arrivals
            live.watchListener = Task { [weak self] in
                for await arrival in arrivals {
                    self?.noteWatchingHeartbeat()
                    self?.sortInBackground([arrival.file], from: .watched)
                }
            }
        }
    }

    /// The last time Folio was watching, so downloads made while it wasn't are still sorted.
    var lastWatched: Date? {
        live?.defaults.object(forKey: Self.watchingSeenKey) as? Date
    }

    func noteWatchingHeartbeat() {
        live?.defaults.set(Date.now, forKey: Self.watchingSeenKey)
    }

    /// Sorts the files already in a watched folder.
    func sortFilesAlreadyIn(_ folder: WatchedFolder) {
        let files = existingFiles(in: folder)
        guard !files.isEmpty else { return }
        sortInBackground(files, from: .watched)
    }

    func existingFiles(in folder: WatchedFolder) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder.url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return (values?.isDirectory != true || values?.isPackage == true) && !Librarian.isUnfinishedDownload(url)
        }
    }

    // MARK: Background sorting

    /// Sorts files without showing them in the Inbox's progress card. Filed
    /// files appear under Recently sorted and in a notification; files that need
    /// a look wait in the Inbox.
    @discardableResult
    func sortInBackground(_ urls: [URL], from source: Librarian.Source) -> [UUID] {
        guard let live, let librarian = live.librarian else { return [] }
        let tickets = librarian.sort(urls, from: source)
        for ticket in tickets {
            live.backgroundTickets.insert(ticket.id)
            backgroundSorting[ticket.id] = ticket.name
        }
        return tickets.map(\.id)
    }

    /// Handles what happened to a file sorted in the background. Returns
    /// `false` for files the student dropped themselves.
    func handleBackground(_ event: Librarian.Event) -> Bool {
        guard let live else { return false }
        let id: UUID = switch event {
        case .progress(let id, _), .filed(let id, _), .needsReview(let id, _), .leftAlone(let id, _), .duplicate(let id, _), .failed(let id, _): id
        }
        guard live.backgroundTickets.contains(id) else { return false }
        let name = backgroundSorting[id] ?? ""

        switch event {
        case .progress:
            return true
        case .filed(_, let record):
            let location = self.location(of: record.subjectID, folder: record.folder)
            withAnimation(Theme.motion()) {
                recentlySorted.insert(SortedFile(record), at: 0)
            }
            live.outcomes[id] = .filed(name: record.name, location: location)
            queueFiledNotification(id: record.id, name: record.name, location: location)
            offerAssessment(from: record)
            scheduleLibraryRefresh()
        case .needsReview(_, let record):
            withAnimation(Theme.motion()) {
                needsReview.append(ReviewItem(record))
            }
            live.outcomes[id] = .needsALook(name: record.name)
            live.notifier.needsALook(record.name, question: record.question)
        case .leftAlone:
            live.outcomes[id] = .leftAlone(name: name)
        case .duplicate:
            live.outcomes[id] = .duplicate(name: name)
        case .failed(_, let message):
            live.outcomes[id] = .failed(name: name, message: message)
        }
        live.backgroundTickets.remove(id)
        backgroundSorting[id] = nil
        return true
    }

    /// Files filed within a couple of seconds of each other share one notification.
    private func queueFiledNotification(id: UUID, name: String, location: String) {
        guard let live else { return }
        live.pendingFiled.append((id, name, location))
        live.notifyTask?.cancel()
        live.notifyTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            live.notifier.filed(live.pendingFiled)
            live.pendingFiled = []
        }
    }

    /// Sorts files for a Shortcut and waits for the result, described in a sentence.
    func sortForShortcut(_ urls: [URL]) async -> String {
        guard let live else { return String(localized: "Folio isn't set up yet. Open Folio to choose your School folder.") }
        let tickets = sortInBackground(urls, from: .shortcut)
        guard !tickets.isEmpty else { return String(localized: "There was nothing Folio could sort.") }
        let deadline = ContinuousClock.now + .seconds(900)
        while ContinuousClock.now < deadline, !tickets.allSatisfy({ live.outcomes[$0] != nil }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let outcomes = tickets.compactMap { live.outcomes.removeValue(forKey: $0) }
        return Self.describe(outcomes)
    }

    static func describe(_ outcomes: [BackgroundOutcome]) -> String {
        var filed: [String] = []
        var waiting = 0, leftAlone = 0, duplicates = 0, failed = 0
        for outcome in outcomes {
            switch outcome {
            case .filed(let name, let location): filed.append(String(localized: "“\(name)” to \(location)", comment: "One filed file, in a list such as Filed “Essay.docx” to English · Essays."))
            case .needsALook: waiting += 1
            case .leftAlone: leftAlone += 1
            case .duplicate: duplicates += 1
            case .failed: failed += 1
            }
        }
        var sentences: [String] = []
        if !filed.isEmpty {
            sentences.append(filed.count <= 3
                ? String(localized: "Filed \(filed.formatted(.list(type: .and))).")
                : String(localized: "Filed \(filed.count) files."))
        }
        if waiting > 0 { sentences.append(String(localized: "\(waiting) files need a look in Folio.")) }
        if leftAlone > 0 { sentences.append(String(localized: "\(leftAlone) files didn't look like schoolwork, so they were left where they were.")) }
        if duplicates > 0 { sentences.append(String(localized: "\(duplicates) files were already filed.")) }
        if failed > 0 { sentences.append(String(localized: "\(failed) files couldn't be read.")) }
        return sentences.isEmpty ? String(localized: "Nothing was sorted.") : sentences.joined(separator: " ")
    }

    // MARK: Notifications

    private func askForNotificationsOnce() {
        guard let live, !live.askedForNotifications else { return }
        live.askedForNotifications = true
        Task {
            notificationsAllowed = await live.notifier.requestPermission()
        }
    }

    func refreshNotificationStatus() async {
        guard let live else { return }
        notificationsAllowed = await live.notifier.isAllowed()
    }

    /// Puts back files from a notification's Undo.
    func undoFiled(_ ids: [UUID]) {
        for id in ids {
            if let file = recentlySorted.first(where: { $0.id == id }) {
                undo(file)
            }
        }
    }

    // MARK: Open at login

    func refreshLoginStatus() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            alert = AlertMessage(title: on ? "Couldn't open Folio at login" : "Couldn't stop Folio opening at login", detail: error.localizedDescription)
        }
        refreshLoginStatus()
    }
}
