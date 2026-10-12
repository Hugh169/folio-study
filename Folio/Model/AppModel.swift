import SwiftUI
import FolioKit

/// The app's state. `AppModel.live()` sorts real files through FolioKit's
/// `Librarian` and keeps everything between launches; `AppModel.sample()` keeps
/// the design's sample content in memory, for previews and screenshots.
@Observable
final class AppModel {
    enum Phase {
        /// First run, or Folio has lost access to the School folder.
        case setup
        case ready
    }

    struct AlertMessage: Identifiable {
        let id = UUID()
        var title: String
        var message: String

        /// Looked up in the string catalog, so both appear in the student's language.
        init(title: LocalizedStringResource, message: LocalizedStringResource) {
            self.title = String(localized: title)
            self.message = String(localized: message)
        }

        /// With a message that's already in the student's language, such as an error's description.
        init(title: LocalizedStringResource, detail: String) {
            self.title = String(localized: title)
            self.message = detail
        }
    }

    var destination: Destination = .today
    var plannerMode: PlannerMode = .week
    /// A day for the planner to show the next time it appears, such as a day
    /// tapped on Today.
    var requestedPlannerDate: Date?
    var phase: Phase = .ready
    /// Setup only needs the School folder again: the settings are fine, but
    /// Folio can no longer reach the folder (it was moved, or access was lost).
    var needsLibraryAgain = false
    /// The student's subjects, document types, folder layout and sorting level.
    var profile: Profile {
        didSet { profileDidChange() }
    }
    /// Each subject's folders and how many files they hold.
    var folders: [Subject.ID: [SubjectFolder]]
    var recentlySorted: [SortedFile]
    var sorting: [SortingItem]
    var needsReview: [ReviewItem]
    var sessions: [StudySession]
    /// Tasks, exams and tests, soonest first.
    var assessments: [Assessment]
    /// Events from the calendars the student plans around, when Calendar is connected.
    var calendarEvents: [BusyBlock] = []
    /// Events from the calendars the student marked as their timetable.
    var timetableEvents: [BusyBlock] = []
    var isCalendarConnected = false
    var calendarList: [CalendarInfo] = []
    var plannedCalendarIDs: Set<String> = []
    var timetableCalendarIDs: Set<String> = []
    var calendarAccessRefused = false
    var usesReminders = false
    var remindersAccessRefused = false
    /// Assessments and links Folio found in files it filed, waiting for a yes or no.
    var assessmentSuggestions: [AssessmentSuggestion] = []
    /// Every file in the library, for search.
    var libraryFiles: [SortedFile] = []
    /// The School folder, when Folio is sorting real files.
    var libraryURL: URL?
    /// Each subject's own folder, such as School/History.
    var subjectFolderURLs: [Subject.ID: URL] = [:]

    /// Folders Folio watches for new files, such as Downloads.
    var watchedFolders: [WatchedFolder] = []
    var isWatchingPaused = false
    /// Files being sorted in the background right now, by ticket.
    var backgroundSorting: [UUID: String] = [:]
    /// Whether macOS lets Folio post notifications.
    var notificationsAllowed: Bool?
    var opensAtLogin = false

    var isImporting = false
    var isAddingSubject = false
    /// Why the on-device AI isn't helping right now, shown as a banner.
    var aiNotice: String?
    /// Why the on-device AI can't help, such as "Apple Intelligence is turned off".
    var aiUnavailableReason: String?
    /// Whether a Claude API key is saved in the keychain.
    var hasClaudeKey = false
    /// Ask Claude about files Folio can't decide. Needs a saved key.
    var usesClaude = false
    /// Also show Claude photos that have almost no readable text.
    var claudeSeesPhotos = false
    var claudeStatus: ClaudeStatus = .unchecked
    /// Claude's requests this month, for Settings.
    var claudeUsage = ClaudeUsageLedger.Usage()
    /// A shared curriculum pack the student opened, waiting for them to choose its subjects.
    var openedPack: CurriculumPack?

    // Studying
    var flashcards: [Flashcard] = []
    /// Things to do for each subject that aren't assessments of their own.
    var todos: [Todo] = []
    /// A subject whose cards the Study screen should open for review, such as
    /// from a plan in the timer window.
    var pendingReview: Subject.ID?
    /// The weekly review sheet is open, such as from Sunday's reminder.
    var isShowingWeeklyReview = false
    var practiceAttempts: [PracticeAttempt] = []
    /// The study session running with the timer, if any.
    var focus: FocusSession?
    /// Finds files by what's in them, once Folio has read the library.
    var librarySearch: LibrarySearch?
    /// Where each file in the search index is, by its ID in the index.
    var indexedLocations: [UUID: URL] = [:]
    /// While Folio reads the library for searching.
    var indexingProgress: (done: Int, total: Int)?
    /// What files are about, from "What's This?", by file.
    var summaries: [URL: [String]] = [:]
    /// The text of each file in the search index, by path, for reading a past paper's times.
    @ObservationIgnored var indexedTexts: [String: String] = [:]
    @ObservationIgnored var focusTimer: Task<Void, Never>?
    @ObservationIgnored var indexTask: Task<Void, Never>?
    @ObservationIgnored let embedder = TextEmbedder()
    /// While Folio reads files that were already in the library.
    var learningProgress: (done: Int, total: Int)?
    var learnedExampleCount = 0
    var alert: AlertMessage?

    let calendar: Calendar
    @ObservationIgnored var live: LiveServices?

    init(
        calendar: Calendar,
        profile: Profile,
        folders: [Subject.ID: [SubjectFolder]],
        recentlySorted: [SortedFile],
        sorting: [SortingItem],
        needsReview: [ReviewItem],
        sessions: [StudySession],
        assessments: [Assessment]
    ) {
        self.calendar = calendar
        self.profile = profile
        self.folders = folders
        self.recentlySorted = recentlySorted
        self.sorting = sorting
        self.needsReview = needsReview
        self.sessions = sessions
        self.assessments = assessments
    }

    /// Weeks start on Monday, as in the design.
    static func makeCalendar() -> Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    /// Where small choices are kept, such as the weekly review: the live
    /// model's own, so the self-test and a fresh start keep theirs apart, or
    /// for previews and screenshots a throwaway one, so they never touch the
    /// student's settings.
    var settings: UserDefaults {
        live?.defaults ?? Self.sampleSettings
    }

    /// The throwaway settings of sample models, emptied when first used.
    static let sampleSettings: UserDefaults = {
        let name = "FolioSamples"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    /// Subjects Folio files into. Archived ones from past terms are kept in
    /// `profile.subjects` so their files still show their names.
    var subjects: [Subject] { profile.sortableSubjects }

    var archivedSubjects: [Subject] { profile.subjects.filter(\.isArchived) }

    func subject(_ id: Subject.ID) -> Subject? {
        profile.subjects.first { $0.id == id }
    }

    func folders(of subjectID: Subject.ID) -> [SubjectFolder] {
        folders[subjectID] ?? []
    }

    func fileCount(of subjectID: Subject.ID) -> Int {
        folders(of: subjectID).reduce(0) { $0 + $1.fileCount }
    }

    /// "Physics · Worksheets", or just "Physics" when there's no folder.
    func location(of subjectID: Subject.ID, folder: String?) -> String {
        [subject(subjectID)?.name, folder].compactMap { $0 }.joined(separator: " · ")
    }

    var isSortingFinished: Bool {
        !sorting.isEmpty && sorting.allSatisfy(\.isDone)
    }

    // MARK: Sorting

    /// Sorts dropped or chosen files. Without the engine (previews), new files
    /// wait in the Inbox for the user to choose a subject.
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let librarian = live?.librarian else {
            needsReview += urls.map {
                ReviewItem(name: $0.lastPathComponent, question: String(localized: "Which subject should this go to?"), suggestions: [], folder: nil)
            }
            destination = .inbox
            return
        }
        // A new drop replaces a batch that's finished.
        if isSortingFinished {
            clearFinishedBatch()
        }
        let tickets = librarian.sort(urls)
        guard !tickets.isEmpty else {
            alert = AlertMessage(title: "Nothing to sort", message: "Those folders don't have any files Folio can sort.")
            return
        }
        sorting += tickets.map { SortingItem(id: $0.id, name: $0.name, detail: String(localized: "Waiting…"), status: .reading) }
        destination = .inbox
    }

    /// Files a waiting file in the chosen subject, and learns from the choice.
    func file(_ item: ReviewItem, in subjectID: Subject.ID) {
        guard let live, let librarian = live.librarian else {
            needsReview.removeAll { $0.id == item.id }
            adjustCount(of: subjectID, folder: item.folder, by: 1)
            recentlySorted.insert(SortedFile(name: item.name, subjectID: subjectID, folder: item.folder, sortedAt: .now), at: 0)
            return
        }
        Task {
            do {
                let record = try await librarian.file(item.id, in: subjectID)
                offerAssessment(from: record)
                withAnimation(Theme.motion()) {
                    needsReview.removeAll { $0.id == item.id }
                    recentlySorted.insert(SortedFile(record), at: 0)
                    if let ticket = live.ticketsByReview.removeValue(forKey: item.id) {
                        updateSortingItem(ticket) {
                            $0.status = .filed(subjectID: record.subjectID, folder: record.folder)
                        }
                    }
                }
                learnedExampleCount = await librarian.learnedExampleCount
                scheduleLibraryRefresh()
            } catch Organizer.Failure.notAllowed(let folder) {
                if await requestAccess(to: folder) {
                    file(item, in: subjectID)
                }
            } catch {
                alert = AlertMessage(title: "Couldn't file “\(item.name)”", detail: error.localizedDescription)
            }
        }
    }

    /// Takes a file back out of its subject and asks where it should go instead.
    func undo(_ file: SortedFile) {
        guard let librarian = live?.librarian else {
            recentlySorted.removeAll { $0.id == file.id }
            adjustCount(of: file.subjectID, folder: file.folder, by: -1)
            needsReview.append(ReviewItem(
                name: file.name,
                question: String(localized: "Moved back. Which subject should it go to?"),
                suggestions: [],
                folder: file.folder
            ))
            return
        }
        Task {
            do {
                let review = try await librarian.putBack(file.id)
                withAnimation(Theme.motion()) {
                    recentlySorted.removeAll { $0.id == file.id }
                    needsReview.append(ReviewItem(review))
                }
                learnedExampleCount = await librarian.learnedExampleCount
                scheduleLibraryRefresh()
            } catch {
                alert = AlertMessage(title: "Couldn't put “\(file.name)” back", detail: error.localizedDescription)
            }
        }
    }

    /// Takes a file off "Needs a look" and leaves it where it is.
    func skip(_ item: ReviewItem) {
        live?.librarian?.skip(item.id)
        withAnimation(Theme.motion()) {
            needsReview.removeAll { $0.id == item.id }
        }
        if let ticket = live?.ticketsByReview.removeValue(forKey: item.id) {
            updateSortingItem(ticket) {
                $0.status = .leftAlone
                $0.detail = String(localized: "Left where it was")
            }
        }
    }

    /// Puts a file Folio left alone under "Needs a look" after all.
    func sortAnyway(_ item: SortingItem) {
        guard let live, let review = live.librarian?.reviewAnyway(item.id) else { return }
        live.ticketsByReview[review.id] = item.id
        withAnimation(Theme.motion()) {
            needsReview.append(ReviewItem(review))
            updateSortingItem(item.id) {
                $0.status = .needsLook
                $0.detail = String(localized: "Waiting for you to choose a subject")
            }
        }
    }

    func clearFinishedBatch() {
        guard sorting.allSatisfy(\.isDone) else { return }
        sorting = []
        live?.librarian?.clearLeftAlone()
    }

    func addSubject(named name: String, colorHex: UInt32, summary: String = "") {
        let subject = Subject(name: name, colorHex: colorHex, summary: summary)
        profile.subjects.append(subject)
        folders[subject.id] = []
    }

    func updateSortingItem(_ id: UUID, _ change: (inout SortingItem) -> Void) {
        guard let index = sorting.firstIndex(where: { $0.id == id }) else { return }
        change(&sorting[index])
    }

    private func adjustCount(of subjectID: Subject.ID, folder: String?, by delta: Int) {
        let name = folder ?? "Unsorted"
        var subjectFolders = folders(of: subjectID)
        if let index = subjectFolders.firstIndex(where: { $0.name == name }) {
            subjectFolders[index].fileCount = max(0, subjectFolders[index].fileCount + delta)
        } else if delta > 0 {
            subjectFolders.append(SubjectFolder(name: name, fileCount: delta))
        }
        folders[subjectID] = subjectFolders
    }

    // MARK: Planner

    func weekStart(containing date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// School hours to show in the planner, if the student has them.
    var school: SchoolHours? { profile.studyPreferences.schoolHours }
}

extension SortedFile {
    init(_ record: FiledRecord) {
        self.init(id: record.id, name: record.name, subjectID: record.subjectID, folder: record.folder, sortedAt: record.filedAt, url: record.url)
    }
}

extension ReviewItem {
    init(_ record: ReviewRecord) {
        self.init(
            id: record.id,
            name: record.name,
            question: record.question,
            suggestions: record.suggestions,
            folder: nil,
            reasons: record.reasons,
            url: record.url,
            blockedFolder: record.blockedFolder
        )
    }
}
