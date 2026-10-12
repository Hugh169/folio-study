import AppKit
import FolioKit
import SwiftUI

/// The real engine behind `AppModel`: settings on disk, the record store, and
/// the librarian that sorts files into the School folder.
final class LiveServices {
    let profileStore: ProfileStore
    let store: FolioStore
    let bookmarks: FolderBookmarks
    let defaults: UserDefaults
    var librarian: Librarian?
    var listener: Task<Void, Never>?
    var saveTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var learningTask: Task<Void, Never>?
    /// Folders Folio has already asked about this session.
    var askedFolders: Set<URL> = []
    /// Which sorting row a waiting file came from, so filing it updates that row too.
    var ticketsByReview: [UUID: UUID] = [:]

    // Background sorting
    let watcher = FolderWatcher()
    let notifier = Notifier()
    var watchListener: Task<Void, Never>?
    var heartbeat: Task<Void, Never>?
    var backgroundTickets: Set<UUID> = []
    var outcomes: [UUID: BackgroundOutcome] = [:]
    var pendingFiled: [(id: UUID, name: String, location: String)] = []
    var notifyTask: Task<Void, Never>?
    var askedForNotifications = false

    // Calendar and Reminders
    var calendarLink: CalendarLink?
    var loadedEventRange: DateInterval?
    /// Watched folders Folio has opened security-scoped access to this session.
    var openedWatchedFolders: Set<String> = []

    // Claude
    /// Where the API key is kept, or `nil` for test runs, which never touch the keychain.
    let keychain: Keychain?
    /// The key, once read from the keychain.
    var claudeKey: String?
    let claudeLedger: ClaudeUsageLedger

    init(supportFolder: URL, defaults: UserDefaults, usesKeychain: Bool) throws {
        profileStore = ProfileStore(url: supportFolder.appending(path: "profile.json"))
        store = try FolioStore(url: supportFolder.appending(path: "Folio.store"))
        bookmarks = FolderBookmarks(defaults: defaults)
        self.defaults = defaults
        keychain = usesKeychain ? .claudeKey : nil
        claudeLedger = ClaudeUsageLedger(defaults: defaults)
    }

    static let usesOnDeviceAIKey = "usesOnDeviceAI"

    var usesOnDeviceAI: Bool {
        get { defaults.object(forKey: Self.usesOnDeviceAIKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.usesOnDeviceAIKey) }
    }
}

/// Remembers the folders the student gave Folio, across restarts. The sandbox
/// only lets Folio back into a folder through a security-scoped bookmark.
struct FolderBookmarks {
    let defaults: UserDefaults
    private static let libraryKey = "libraryBookmark"
    private static let grantedKey = "grantedFolderBookmarks"

    func saveLibrary(_ url: URL) throws {
        defaults.set(try url.bookmarkData(options: .withSecurityScope), forKey: Self.libraryKey)
    }

    /// The School folder, with access started, or `nil` if Folio can't reach it any more.
    func restoreLibrary() -> URL? {
        guard let data = defaults.data(forKey: Self.libraryKey), let url = resolve(data) else { return nil }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            if let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                defaults.set(fresh, forKey: Self.libraryKey)
            }
            return url
        }
        return nil
    }

    /// A folder the student let Folio move files out of.
    func saveGranted(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        var list = defaults.array(forKey: Self.grantedKey) as? [Data] ?? []
        list.append(data)
        defaults.set(list, forKey: Self.grantedKey)
    }

    /// Starts access to every folder the student granted.
    func restoreGranted() {
        for data in defaults.array(forKey: Self.grantedKey) as? [Data] ?? [] {
            _ = resolve(data)
        }
    }

    private func resolve(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}

extension AppModel {
    /// Folio as it really runs: loads the settings and records, and shows
    /// first-run setup when there's no School folder yet.
    /// - Parameters:
    ///   - readsCalendar: Off for test runs, which use made-up events instead.
    ///   - usesKeychain: Off for test runs, so macOS never asks about the keychain.
    static func live(supportFolder: URL? = nil, defaults: UserDefaults = .standard, readsCalendar: Bool = true, usesKeychain: Bool = true) -> AppModel {
        let model = AppModel(
            calendar: makeCalendar(),
            profile: .starter(),
            folders: [:],
            recentlySorted: [],
            sorting: [],
            needsReview: [],
            sessions: [],
            assessments: []
        )
        model.start(supportFolder: supportFolder, defaults: defaults, readsCalendar: readsCalendar, usesKeychain: usesKeychain)
        return model
    }

    private func start(supportFolder: URL?, defaults: UserDefaults, readsCalendar: Bool, usesKeychain: Bool) {
        do {
            let support = try supportFolder ?? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Folio", directoryHint: .isDirectory)
            let live = try LiveServices(supportFolder: support, defaults: defaults, usesKeychain: usesKeychain)
            self.live = live
            live.notifier.register()
            live.notifier.onUndo = { [weak self] ids in self?.undoFiled(ids) }
            live.notifier.onOpen = { [weak self] destination in self?.destination = destination }
            live.notifier.onWeeklyReview = { [weak self] in
                self?.destination = .progress
                self?.isShowingWeeklyReview = true
            }
            loadWatchedFolders()
            refreshLoginStatus()
            loadPlanner()
            loadStudy()
            if readsCalendar {
                restoreCalendar()
            }
            restoreClaude()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteWatchingHeartbeat() }
            }
            let saved = try live.profileStore.load()
            if let saved {
                profile = saved
            }
            live.bookmarks.restoreGranted()
            if saved != nil, let library = live.bookmarks.restoreLibrary() {
                open(library: library)
                phase = .ready
            } else {
                needsLibraryAgain = saved != nil
                phase = .setup
            }
        } catch ProfileStore.StoreError.newerVersion {
            phase = .setup
            alert = AlertMessage(title: "Settings from a newer Folio", message: "Your settings were saved by a newer version of Folio. Update Folio to use them.")
        } catch {
            phase = .setup
            alert = AlertMessage(title: "Folio couldn't open its records", detail: error.localizedDescription)
        }
    }

    /// Starts sorting into `library` and loads what's waiting and what was filed.
    func open(library: URL) {
        guard let live else { return }
        live.listener?.cancel()
        live.librarian?.shutDown()
        var options = Librarian.Options()
        options.usesOnDeviceAI = live.usesOnDeviceAI
        let librarian = Librarian(library: library, profile: profile, store: live.store, options: options)
        live.librarian = librarian
        libraryURL = library
        recentlySorted = librarian.recentFiles().map(SortedFile.init)
        needsReview = librarian.reviewQueue().map(ReviewItem.init)
        learnedExampleCount = live.store.examples().count
        sorting = []
        let events = librarian.events
        live.listener = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        refreshClasses()
        librarian.update(assessments: assessments)
        updateClaudeVoter()
        Task {
            await refreshLibrary()
            await refreshAIStatus()
            await refreshNotificationStatus()
            await startWatching(since: lastWatched)
            await librarian.prewarm()
        }
        rebuildSearch()
        // Read new and changed files for searching once launch has settled.
        scheduleSearchIndexUpdate(after: .seconds(30))
        // Remember when Folio was last watching, so downloads made while it's
        // closed are sorted next time.
        live.heartbeat?.cancel()
        live.heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                self?.noteWatchingHeartbeat()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func handle(_ event: Librarian.Event) {
        if handleBackground(event) { return }
        switch event {
        case .progress(let id, let message):
            updateSortingItem(id) { $0.detail = message }
        case .filed(let id, let record):
            withAnimation(Theme.motion()) {
                updateSortingItem(id) {
                    $0.status = .filed(subjectID: record.subjectID, folder: record.folder)
                    $0.detail = record.detail.isEmpty ? String(localized: "Filed") : record.detail
                }
                recentlySorted.insert(SortedFile(record), at: 0)
            }
            offerAssessment(from: record)
            scheduleLibraryRefresh()
        case .needsReview(let id, let record):
            live?.ticketsByReview[record.id] = id
            withAnimation(Theme.motion()) {
                updateSortingItem(id) {
                    $0.status = .needsLook
                    $0.detail = record.detail.isEmpty ? String(localized: "Needs a look") : record.detail
                }
                needsReview.append(ReviewItem(record))
            }
            if let folder = record.blockedFolder {
                askForAccess(to: folder)
            }
        case .leftAlone(let id, let detail):
            updateSortingItem(id) {
                $0.status = .leftAlone
                $0.detail = detail
            }
        case .duplicate(let id, let detail):
            updateSortingItem(id) {
                $0.status = .duplicate
                $0.detail = detail
            }
        case .failed(let id, let message):
            updateSortingItem(id) {
                $0.status = .failed
                $0.detail = message
            }
        }
    }

    // MARK: The library

    /// Recounts the files in each subject's folder.
    func refreshLibrary() async {
        guard let librarian = live?.librarian else { return }
        let snapshot = await librarian.scan()
        var folders: [Subject.ID: [SubjectFolder]] = [:]
        for subject in profile.subjects {
            var list = (snapshot.folders[subject.id] ?? []).map {
                SubjectFolder(name: $0.name, fileCount: $0.fileCount, url: $0.url)
            }
            if let loose = snapshot.looseFileCounts[subject.id], loose > 0 {
                list.append(SubjectFolder(name: String(localized: "Other files", comment: "Files straight inside a subject's folder, not in a folder of their own"), fileCount: loose, url: snapshot.subjectFolders[subject.id]))
            }
            folders[subject.id] = list
        }
        self.folders = folders
        subjectFolderURLs = snapshot.subjectFolders
        libraryFiles = snapshot.files.map {
            SortedFile(name: $0.name, subjectID: $0.subjectID, folder: $0.folder, sortedAt: $0.modified ?? .distantPast, url: $0.url)
        }
        if indexTask == nil || indexingProgress == nil {
            scheduleSearchIndexUpdate()
        }
    }

    /// Recounts soon, once a burst of changes has settled.
    func scheduleLibraryRefresh() {
        guard let live else { return }
        live.refreshTask?.cancel()
        live.refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshLibrary()
        }
    }

    /// Checks whether the on-device AI can help, for the banner.
    func refreshAIStatus() async {
        guard let librarian = live?.librarian else { return }
        let reason = await librarian.aiUnavailableReason()
        aiUnavailableReason = reason
        aiNotice = reason.map {
            String(localized: "\($0), so Folio is sorting with keywords and your past choices.", comment: "The first part says why the on-device AI can't help, such as “Apple Intelligence is turned off”")
        }
    }

    // MARK: Settings

    var usesOnDeviceAI: Bool {
        get { live?.usesOnDeviceAI ?? true }
        set {
            live?.usesOnDeviceAI = newValue
            live?.librarian?.setUsesOnDeviceAI(newValue)
            Task { await refreshAIStatus() }
        }
    }

    /// Saves the settings shortly after the last change and passes them to the librarian.
    func profileDidChange() {
        guard let live else { return }
        live.librarian?.update(profile: profile)
        refreshClasses()
        live.saveTask?.cancel()
        let profile = profile
        live.saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try live.profileStore.save(profile)
            } catch {
                alert = AlertMessage(title: "Couldn't save your settings", detail: error.localizedDescription)
            }
            await refreshLibrary()
        }
    }

    /// Finishes first-run setup with everything the student chose: makes the
    /// subject folders, saves the settings, starts sorting and watching, and
    /// opens the Library, or the Planner with a first week planned.
    func finishSetup(library: URL, profile: Profile, watchesDownloads: Bool, watchedFolders folders: [URL], plansFirstWeek: Bool) {
        guard let live else { return }
        do {
            if FolderTemplate(profile.folderTemplate).subjectIndex == 0 {
                for subject in profile.subjects {
                    let folder = library.appending(path: FolderTemplate.cleanFolderName(subject.effectiveFolderName), directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
            }
            try live.profileStore.save(profile)
            try live.bookmarks.saveLibrary(library)
            self.profile = profile
            open(library: library)
            if watchesDownloads, let downloads = watchedFolders.first(where: \.isDownloads) {
                setWatching(downloads, on: true)
            }
            for folder in folders {
                Task { await addWatchedFolder(folder) }
            }
            phase = .ready
            if plansFirstWeek {
                // On a Sunday afternoon or evening that's next week, so the
                // Planner opens on it.
                let week = weekToPlan()
                _ = planWeek(containing: week)
                if week > .now {
                    requestedPlannerDate = week
                }
                destination = .planner
            } else {
                destination = .today
            }
        } catch {
            alert = AlertMessage(title: "Couldn't finish setting up", detail: error.localizedDescription)
        }
    }

    /// Finishes setup the way the first version did, from the general starter
    /// subjects. The self-test uses this.
    func finishSetup(library: URL, level: StudyLevel = .school, subjects: [Subject], folderTemplate: String, learnsFromExistingFiles: Bool, watchesDownloads: Bool = false) {
        guard let live else { return }
        if watchesDownloads, let downloads = watchedFolders.first(where: \.isDownloads) {
            setWatching(downloads, on: true)
        }
        do {
            var profile = level == self.profile.level ? self.profile : (level == .university ? Profile.university() : Profile.starter())
            profile.subjects = subjects
            profile.folderTemplate = folderTemplate
            if FolderTemplate(folderTemplate).subjectIndex == 0 {
                for subject in subjects {
                    let folder = library.appending(path: FolderTemplate.cleanFolderName(subject.effectiveFolderName), directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
            }
            try live.profileStore.save(profile)
            try live.bookmarks.saveLibrary(library)
            self.profile = profile
            open(library: library)
            destination = .library
            phase = .ready
            if learnsFromExistingFiles {
                learnFromLibrary()
            }
        } catch {
            alert = AlertMessage(title: "Couldn't finish setting up", detail: error.localizedDescription)
        }
    }

    /// Moves Folio to a different School folder.
    func changeLibrary(to url: URL) {
        guard let live else { return }
        do {
            try live.bookmarks.saveLibrary(url)
            open(library: url)
            needsLibraryAgain = false
            phase = .ready
        } catch {
            alert = AlertMessage(title: "Couldn't use that folder", detail: error.localizedDescription)
        }
    }

    /// Reads files already in the subject folders, so Folio starts out knowing
    /// what the student's files look like.
    func learnFromLibrary() {
        guard let live, let librarian = live.librarian else { return }
        live.learningTask?.cancel()
        learningProgress = (0, 0)
        live.learningTask = Task {
            await librarian.learnFromLibrary { done, total in
                self.learningProgress = (done, total)
            }
            learningProgress = nil
            learnedExampleCount = await librarian.learnedExampleCount
        }
    }

    func forgetLearning() {
        guard let librarian = live?.librarian else { return }
        Task {
            await librarian.forgetLearning()
            learnedExampleCount = 0
        }
    }

    // MARK: Folder access

    /// Asks the student to let Folio move files out of `folder`. The sandbox
    /// normally allows this for files they drop or choose, so it's a fallback.
    func requestAccess(to folder: URL) async -> Bool {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Folio needs your permission to move files out of “\(folder.lastPathComponent)”.")
        panel.prompt = String(localized: "Allow")
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        _ = url.startAccessingSecurityScopedResource()
        live?.bookmarks.saveGranted(url)
        return true
    }

    /// Asks once per folder, then files everything that was waiting on it.
    private func askForAccess(to folder: URL) {
        guard let live, live.askedFolders.insert(folder).inserted else { return }
        Task {
            guard await requestAccess(to: folder) else { return }
            for item in needsReview where item.blockedFolder == folder {
                if let subject = item.suggestions.first {
                    file(item, in: subject)
                }
            }
        }
    }

    // MARK: Finder

    func showInFinder(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
