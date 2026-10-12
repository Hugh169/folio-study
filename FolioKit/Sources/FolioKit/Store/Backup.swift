import Foundation
import SwiftData

/// Everything Folio knows, in one file the student can keep or take to a new
/// Mac: settings, what was filed where, files waiting under "Needs a look",
/// what Folio learned from them, the planner with each session's plan,
/// to-dos, flashcards and practised past papers. Paths inside the School folder are kept relative to it, so a backup
/// works wherever it ends up.
///
/// Left out on purpose: the Claude key, which stays in the keychain; folder
/// permissions, which only work on the Mac that made them; the Undo history,
/// whose moves were made on that Mac; and the search index, which Folio
/// builds again from the files.
public struct FolioBackup: Codable, Sendable {
    /// 1 is Folio 0.4's, with deadlines. 2 is Folio 0.5's, with assessments.
    /// 3 adds flashcards and practised past papers. 4 adds to-dos, and plans
    /// in study sessions.
    public static let currentVersion = 4
    public static let fileExtension = "foliobackup"

    public enum BackupError: Error, Equatable {
        /// Made by a newer version of Folio.
        case newerVersion(Int)
    }

    public var version: Int
    public var createdAt: Date
    public var profile: Profile
    public var filed: [Filed]
    public var waiting: [Waiting]
    public var examples: [Example]
    public var sessions: [StudySession]
    /// Version 1's deadlines, which restore as tasks.
    public var deadlines: [DeadlineEntry]?
    public var assessments: [AssessmentEntry]?
    public var flashcards: [Flashcard]?
    public var practice: [PracticeAttempt]?
    public var todos: [Todo]?
    public var preferences: Preferences

    /// A file Folio filed, by its place in the School folder.
    public struct Filed: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var subjectID: UUID
        public var relativePath: String
        public var originalPath: String
        public var documentType: String?
        public var year: Int?
        public var exam: String?
        public var contentHash: String?
        public var detail: String
        public var reasons: [String]
        public var filedAt: Date
        public var chosenByStudent: Bool
        public var vector: Data?
        public var vectorModel: String?
        public var assessmentID: UUID?
        public var fileRole: String?
    }

    /// A file waiting under "Needs a look", where it was.
    public struct Waiting: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var path: String
        public var question: String
        public var suggestions: [UUID]
        public var reasons: [String]
        public var documentType: String?
        public var year: Int?
        public var exam: String?
        public var contentHash: String?
        public var detail: String
        public var vector: Data?
        public var vectorModel: String?
        public var addedAt: Date
        public var previousSubjectID: UUID?
    }

    /// Something Folio learned from a file. `path` is relative to the School
    /// folder when the file was in it.
    public struct Example: Codable, Sendable, Equatable {
        public var id: UUID
        public var subjectID: UUID
        public var name: String
        public var path: String
        public var isInLibrary: Bool
        public var vector: Data
        public var model: String
        public var source: String
        public var addedAt: Date
        public var itemID: UUID?
    }

    public struct DeadlineEntry: Codable, Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var subjectID: UUID
        public var due: Date
        public var isDone: Bool
        /// The matching reminder, which may not exist on another Mac.
        public var reminderID: String?
        public var sourcePath: String?
        public var createdAt: Date
    }

    public struct AssessmentEntry: Codable, Sendable, Equatable {
        public var assessment: Assessment
        /// The matching reminder, which may not exist on another Mac.
        public var reminderID: String?
        public var sourcePath: String?
        public var createdAt: Date
    }

    /// Choices the app keeps outside the settings file.
    public struct Preferences: Codable, Sendable, Equatable {
        public var calendars: [CalendarChoice]
        public var usesReminders: Bool
        public var watchesDownloads: Bool
        /// Other folders Folio watched, which it has to be allowed into again.
        public var watchedFolders: [String]
        public var usesOnDeviceAI: Bool
        public var usesClaude: Bool
        public var claudeSeesPhotos: Bool

        public init(calendars: [CalendarChoice] = [], usesReminders: Bool = false, watchesDownloads: Bool = false, watchedFolders: [String] = [], usesOnDeviceAI: Bool = true, usesClaude: Bool = false, claudeSeesPhotos: Bool = false) {
            self.calendars = calendars
            self.usesReminders = usesReminders
            self.watchesDownloads = watchesDownloads
            self.watchedFolders = watchedFolders
            self.usesOnDeviceAI = usesOnDeviceAI
            self.usesClaude = usesClaude
            self.claudeSeesPhotos = claudeSeesPhotos
        }
    }

    /// A calendar the student chose, with its name in case its ID is
    /// different on another Mac.
    public struct CalendarChoice: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var account: String
        public var plansAround: Bool
        public var isTimetable: Bool

        public init(id: String, title: String, account: String, plansAround: Bool, isTimetable: Bool) {
            self.id = id
            self.title = title
            self.account = account
            self.plansAround = plansAround
            self.isTimetable = isTimetable
        }
    }

    // MARK: Making a backup

    /// Collects everything in the store. `library` is the School folder, so
    /// paths inside it can be kept relative.
    @MainActor
    public init(profile: Profile, store: FolioStore, library: URL, preferences: Preferences, now: Date = .now) {
        let base = Self.folderPath(library)
        version = Self.currentVersion
        createdAt = now
        self.profile = profile
        filed = store.filedItems().map { item in
            Filed(
                id: item.id, name: item.name, subjectID: item.subjectID, relativePath: item.relativePath,
                originalPath: item.originalPath, documentType: item.documentType, year: item.year, exam: item.exam,
                contentHash: item.contentHash, detail: item.detail, reasons: item.reasons, filedAt: item.filedAt,
                chosenByStudent: item.chosenByStudent, vector: item.vector, vectorModel: item.vectorModel,
                assessmentID: item.assessmentID, fileRole: item.fileRoleName
            )
        }
        waiting = store.reviewEntries().map { entry in
            Waiting(
                id: entry.id, name: entry.name, path: entry.path, question: entry.question, suggestions: entry.suggestions,
                reasons: entry.reasons, documentType: entry.documentType, year: entry.year, exam: entry.exam,
                contentHash: entry.contentHash, detail: entry.detail, vector: entry.vector, vectorModel: entry.vectorModel,
                addedAt: entry.addedAt, previousSubjectID: entry.previousSubjectID
            )
        }
        examples = store.examples().map { example in
            let isInLibrary = example.path.hasPrefix(base)
            return Example(
                id: example.id, subjectID: example.subjectID, name: example.name,
                path: isInLibrary ? String(example.path.dropFirst(base.count)) : example.path, isInLibrary: isInLibrary,
                vector: example.vector, model: example.model, source: example.sourceName, addedAt: example.addedAt, itemID: example.itemID
            )
        }
        sessions = store.plannedSessions().map(\.session)
        deadlines = nil
        assessments = store.assessmentRecords().map { record in
            AssessmentEntry(assessment: record.assessment, reminderID: record.reminderID, sourcePath: record.sourcePath, createdAt: record.createdAt)
        }
        flashcards = store.flashcardRecords().map(\.card)
        practice = store.practiceRecords().map(\.attempt)
        todos = store.todoRecords().map(\.todo)
        self.preferences = preferences
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FolioBackup {
        let backup = try JSONDecoder().decode(FolioBackup.self, from: data)
        guard backup.version <= currentVersion else { throw BackupError.newerVersion(backup.version) }
        var migrated = backup
        migrated.profile = backup.profile.migrated()
        return migrated
    }

    // MARK: Restoring

    /// What a restore brought back, and what it couldn't.
    public struct Restored: Sendable, Equatable {
        public var filed: Int
        public var waiting: Int
        /// Waiting files that weren't where they used to be.
        public var waitingNotFound: Int
        public var examples: Int
        public var sessions: Int
        public var assessments: Int
        public var flashcards: Int = 0
        public var practice: Int = 0
        public var todos: Int = 0
    }

    /// Replaces everything in `store` with the backup, with paths inside the
    /// School folder moved onto `library`. Waiting files are kept only if
    /// `fileExists` finds them, and reminder links only if `reminderExists`
    /// does. The Undo history is cleared, since it describes another Mac.
    @MainActor
    @discardableResult
    public func restore(into store: FolioStore, library: URL, fileExists: (URL) -> Bool, reminderExists: (String) -> Bool = { _ in true }) throws -> Restored {
        let base = Self.folderPath(library)
        try store.removeAllRecords()

        for item in filed {
            let record = FiledItem(
                id: item.id, name: item.name, subjectID: item.subjectID, relativePath: item.relativePath,
                originalPath: item.originalPath, facets: Facets(documentType: item.documentType, year: item.year, exam: item.exam),
                contentHash: item.contentHash, detail: item.detail, reasons: item.reasons, filedAt: item.filedAt,
                chosenByStudent: item.chosenByStudent
            )
            record.vector = item.vector
            record.vectorModel = item.vectorModel
            record.assessmentID = item.assessmentID
            record.fileRoleName = item.fileRole
            store.insert(record)
        }

        var waitingNotFound = 0
        for entry in waiting {
            let url = URL(filePath: entry.path)
            guard fileExists(url) else {
                waitingNotFound += 1
                continue
            }
            let record = ReviewEntry(
                id: entry.id, name: entry.name, url: url, bookmark: nil, question: entry.question,
                suggestions: entry.suggestions, reasons: entry.reasons,
                facets: Facets(documentType: entry.documentType, year: entry.year, exam: entry.exam),
                contentHash: entry.contentHash, detail: entry.detail, embedding: nil, addedAt: entry.addedAt,
                previousSubjectID: entry.previousSubjectID
            )
            record.vector = entry.vector
            record.vectorModel = entry.vectorModel
            store.insert(record)
        }

        for example in examples {
            let record = LearnedExample(
                id: example.id, subjectID: example.subjectID, name: example.name,
                path: example.isInLibrary ? base + example.path : example.path,
                embedding: TextEmbedder.Embedding(vector: [], model: example.model),
                source: LearnedExample.Source(rawValue: example.source) ?? .choice, addedAt: example.addedAt, itemID: example.itemID
            )
            record.vector = example.vector
            store.insert(record)
        }

        for session in sessions {
            store.insert(PlannedSession(session))
        }
        let entries = allAssessments
        for entry in entries {
            store.insert(AssessmentRecord(
                entry.assessment,
                reminderID: entry.reminderID.flatMap { reminderExists($0) ? $0 : nil },
                sourcePath: entry.sourcePath,
                createdAt: entry.createdAt
            ))
        }
        for card in flashcards ?? [] {
            store.insert(FlashcardRecord(card))
        }
        for attempt in practice ?? [] {
            store.insert(PracticeRecord(attempt))
        }
        for todo in todos ?? [] {
            store.insert(TodoRecord(todo))
        }
        store.save()
        return Restored(
            filed: filed.count, waiting: waiting.count - waitingNotFound, waitingNotFound: waitingNotFound,
            examples: examples.count, sessions: sessions.count, assessments: entries.count,
            flashcards: flashcards?.count ?? 0, practice: practice?.count ?? 0, todos: todos?.count ?? 0
        )
    }

    /// The backup's assessments, with version 1's deadlines turned into tasks.
    public var allAssessments: [AssessmentEntry] {
        let old = (deadlines ?? []).map { deadline in
            AssessmentEntry(
                assessment: Assessment(
                    id: deadline.id, title: deadline.title, subjectID: deadline.subjectID, kind: .task, due: deadline.due,
                    status: deadline.isDone ? .submitted : .notStarted, source: deadline.sourcePath == nil ? .typed : .file
                ),
                reminderID: deadline.reminderID, sourcePath: deadline.sourcePath, createdAt: deadline.createdAt
            )
        }
        return (assessments ?? []) + old
    }

    /// A folder's path ending in "/", so paths inside it can be cut down to relative ones.
    private static func folderPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }
}
