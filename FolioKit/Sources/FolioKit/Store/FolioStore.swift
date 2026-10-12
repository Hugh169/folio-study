import Foundation
import OSLog
import SwiftData

/// Opens Folio's SwiftData store and answers the questions the app asks of it.
@MainActor
public final class FolioStore {
    public let container: ModelContainer
    public let context: ModelContext

    /// Opens the store at `url`, or an in-memory one for tests and previews.
    public init(url: URL?) throws {
        let schema = Schema(versionedSchema: FolioSchemaV5.self)
        let configuration = if let url {
            ModelConfiguration(schema: schema, url: url)
        } else {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        container = try ModelContainer(for: schema, migrationPlan: FolioMigrationPlan.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// `Folio.store` in Folio's Application Support folder.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "Folio/Folio.store")
    }

    public func insert(_ model: some PersistentModel) {
        context.insert(model)
    }

    public func delete(_ model: some PersistentModel) {
        context.delete(model)
    }

    public func save() {
        do {
            try context.save()
        } catch {
            Self.log.error("Couldn't save Folio's records: \(error, privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "Folio", category: "Store")

    // MARK: Filed files

    /// Files still filed, newest first.
    public func filedItems(limit: Int? = nil) -> [FiledItem] {
        var descriptor = FetchDescriptor<FiledItem>(
            predicate: #Predicate { $0.undoneAt == nil },
            sortBy: [SortDescriptor(\.filedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    public func filedItem(_ id: UUID) -> FiledItem? {
        var descriptor = FetchDescriptor<FiledItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func filedItem(withHash hash: String) -> FiledItem? {
        var descriptor = FetchDescriptor<FiledItem>(
            predicate: #Predicate { $0.contentHash == hash && $0.undoneAt == nil },
            sortBy: [SortDescriptor(\.filedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: Needs a look

    public func reviewEntries() -> [ReviewEntry] {
        (try? context.fetch(FetchDescriptor<ReviewEntry>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
    }

    public func reviewEntry(_ id: UUID) -> ReviewEntry? {
        var descriptor = FetchDescriptor<ReviewEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Contents Folio has filed or is waiting on, for spotting duplicates.
    public func knownHashes() -> Set<String> {
        let filed = filedItems().compactMap(\.contentHash)
        let waiting = reviewEntries().compactMap(\.contentHash)
        return Set(filed + waiting)
    }

    // MARK: Journal

    public func journal(for itemID: UUID) -> [JournalEntry] {
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.itemID == itemID },
            sortBy: [SortDescriptor(\.date)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Planner

    public func plannedSessions() -> [PlannedSession] {
        (try? context.fetch(FetchDescriptor<PlannedSession>(sortBy: [SortDescriptor(\.start)]))) ?? []
    }

    /// Replaces the saved sessions with `sessions`, keeping the store in step with the planner.
    public func replaceSessions(with sessions: [StudySession]) {
        let saved = plannedSessions()
        let wanted = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in saved {
            if let session = wanted[record.id] {
                record.update(from: session)
            } else {
                context.delete(record)
            }
        }
        let savedIDs = Set(saved.map(\.id))
        for session in sessions where !savedIDs.contains(session.id) {
            context.insert(PlannedSession(session))
        }
        save()
    }

    public func assessmentRecords() -> [AssessmentRecord] {
        (try? context.fetch(FetchDescriptor<AssessmentRecord>(sortBy: [SortDescriptor(\.due)]))) ?? []
    }

    public func assessmentRecord(_ id: UUID) -> AssessmentRecord? {
        var descriptor = FetchDescriptor<AssessmentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Files linked to an assessment, oldest first.
    public func filedItems(linkedTo assessmentID: UUID) -> [FiledItem] {
        let descriptor = FetchDescriptor<FiledItem>(
            predicate: #Predicate { $0.assessmentID == assessmentID && $0.undoneAt == nil },
            sortBy: [SortDescriptor(\.filedAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Links a filed file to an assessment, or unlinks it when `assessmentID` is `nil`.
    public func link(_ itemID: UUID, to assessmentID: UUID?, role: FileRole?) {
        guard let item = filedItem(itemID) else { return }
        item.assessmentID = assessmentID
        item.fileRole = assessmentID == nil ? nil : role
        save()
    }

    // MARK: Learning

    public func examples() -> [LearnedExample] {
        (try? context.fetch(FetchDescriptor<LearnedExample>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
    }

    /// Forgets the examples learned from a filed item, returning their IDs.
    @discardableResult
    public func deleteExamples(learnedFrom itemID: UUID) -> Set<UUID> {
        let descriptor = FetchDescriptor<LearnedExample>(predicate: #Predicate { $0.itemID == itemID })
        let examples = (try? context.fetch(descriptor)) ?? []
        examples.forEach(context.delete)
        return Set(examples.map(\.id))
    }

    public func deleteAllExamples() {
        try? context.delete(model: LearnedExample.self)
    }

    // MARK: Studying

    public func flashcardRecords() -> [FlashcardRecord] {
        (try? context.fetch(FetchDescriptor<FlashcardRecord>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// Saves new and changed cards.
    public func save(_ cards: [Flashcard]) {
        let ids = Set(cards.map(\.id))
        let saved = Dictionary(
            ((try? context.fetch(FetchDescriptor<FlashcardRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for card in cards {
            if let record = saved[card.id] {
                record.update(from: card)
            } else {
                context.insert(FlashcardRecord(card))
            }
        }
        save()
    }

    public func deleteFlashcards(_ ids: Set<UUID>) {
        let records = (try? context.fetch(FetchDescriptor<FlashcardRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        records.forEach(context.delete)
        save()
    }

    public func practiceRecords() -> [PracticeRecord] {
        (try? context.fetch(FetchDescriptor<PracticeRecord>(sortBy: [SortDescriptor(\.date)]))) ?? []
    }

    public func save(_ attempt: PracticeAttempt) {
        let id = attempt.id
        var descriptor = FetchDescriptor<PracticeRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try? context.fetch(descriptor).first {
            record.update(from: attempt)
        } else {
            context.insert(PracticeRecord(attempt))
        }
        save()
    }

    // MARK: To-dos

    public func todoRecords() -> [TodoRecord] {
        (try? context.fetch(FetchDescriptor<TodoRecord>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    public func save(_ todo: Todo) {
        let id = todo.id
        var descriptor = FetchDescriptor<TodoRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try? context.fetch(descriptor).first {
            record.update(from: todo)
        } else {
            context.insert(TodoRecord(todo))
        }
        save()
    }

    public func deleteTodo(_ id: UUID) {
        var descriptor = FetchDescriptor<TodoRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try? context.fetch(descriptor).first {
            context.delete(record)
            save()
        }
    }

    // MARK: Search index

    public func indexedFiles() -> [IndexedFile] {
        (try? context.fetch(FetchDescriptor<IndexedFile>())) ?? []
    }

    /// Records what's in the file at `path`, replacing what was there.
    public func index(path: String, modified: Date?, text: String, embedding: TextEmbedder.Embedding?) {
        var descriptor = FetchDescriptor<IndexedFile>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        if let record = try? context.fetch(descriptor).first {
            record.modified = modified
            record.text = text
            record.vector = embedding.map { VectorCoding.data(from: $0.vector) }
            record.vectorModel = embedding?.model
            record.indexedAt = .now
        } else {
            context.insert(IndexedFile(path: path, modified: modified, text: text, embedding: embedding))
        }
    }

    /// Forgets files that aren't in the library any more.
    public func removeIndexed(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for record in indexedFiles() where paths.contains(record.path) {
            context.delete(record)
        }
        save()
    }

    // MARK: Restoring

    /// Deletes every record, before a backup is restored.
    public func removeAllRecords() throws {
        try context.delete(model: FiledItem.self)
        try context.delete(model: JournalEntry.self)
        try context.delete(model: ReviewEntry.self)
        try context.delete(model: LearnedExample.self)
        try context.delete(model: PlannedSession.self)
        try context.delete(model: AssessmentRecord.self)
        try context.delete(model: FlashcardRecord.self)
        try context.delete(model: PracticeRecord.self)
        try context.delete(model: IndexedFile.self)
        try context.delete(model: TodoRecord.self)
        try context.save()
    }
}
