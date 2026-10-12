import Foundation
import SwiftData

/// Everything Folio 0.1 recorded, saved with SwiftData. Settings live
/// separately in profile.json. These models describe stores saved by that
/// version, so don't change them: copy a model into a new version first (see
/// `FolioSchemaV2` and `FolioMigrationPlan`), so students' records carry over.
public enum FolioSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [FiledItem.self, JournalEntry.self, ReviewEntry.self, LearnedExample.self]
    }

    /// A file Folio moved into the library.
    @Model public final class FiledItem {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var subjectID: UUID
        /// Where it is inside the library, such as "History/Past Papers/2023 HSC.pdf".
        public var relativePath: String
        /// Where it was before Folio moved it.
        public var originalPath: String
        public var documentType: String?
        public var year: Int?
        public var exam: String?
        public var contentHash: String?
        /// What Folio worked out about it, such as "Past Papers · HSC 2023 · 12 pages".
        public var detail: String
        public var reasons: [String]
        public var filedAt: Date
        /// The student chose the subject, rather than Folio filing it on its own.
        public var chosenByStudent: Bool
        /// Finds the file again if the student moves it within the library.
        public var bookmark: Data?
        /// The file's embedding, so it can become an example if it's refiled.
        public var vector: Data?
        public var vectorModel: String?
        /// Set when the file was put back.
        public var undoneAt: Date?

        public init(
            id: UUID = UUID(),
            name: String,
            subjectID: UUID,
            relativePath: String,
            originalPath: String,
            facets: Facets,
            contentHash: String?,
            detail: String,
            reasons: [String],
            filedAt: Date = .now,
            chosenByStudent: Bool,
            bookmark: Data? = nil,
            embedding: TextEmbedder.Embedding? = nil
        ) {
            self.id = id
            self.name = name
            self.subjectID = subjectID
            self.relativePath = relativePath
            self.originalPath = originalPath
            self.documentType = facets.documentType
            self.year = facets.year
            self.exam = facets.exam
            self.contentHash = contentHash
            self.detail = detail
            self.reasons = reasons
            self.filedAt = filedAt
            self.chosenByStudent = chosenByStudent
            self.bookmark = bookmark
            self.vector = embedding.map { VectorCoding.data(from: $0.vector) }
            self.vectorModel = embedding?.model
        }

        public var facets: Facets {
            Facets(documentType: documentType, year: year, exam: exam)
        }

        public var embedding: TextEmbedder.Embedding? {
            VectorCoding.embedding(vector, model: vectorModel)
        }
    }

    /// One move Folio made, so it can be explained and undone.
    @Model public final class JournalEntry {
        public enum Action: String, Codable, Sendable {
            /// Moved into the library.
            case file
            /// Put back where it came from, or into Folio Inbox.
            case putBack
        }

        @Attribute(.unique) public var id: UUID
        /// Moves made together, such as one drop of files.
        public var batchID: UUID
        public var date: Date
        public var actionName: String
        public var fromPath: String
        public var toPath: String
        public var itemID: UUID?

        public init(id: UUID = UUID(), batchID: UUID, date: Date = .now, action: Action, from: URL, to: URL, itemID: UUID?) {
            self.id = id
            self.batchID = batchID
            self.date = date
            self.actionName = action.rawValue
            self.fromPath = from.path(percentEncoded: false)
            self.toPath = to.path(percentEncoded: false)
            self.itemID = itemID
        }

        public var action: Action? { Action(rawValue: actionName) }
    }

    /// A file waiting under "Needs a look". It stays where it is until the
    /// student chooses a subject.
    @Model public final class ReviewEntry {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var path: String
        /// Lets Folio reach the file again after a restart.
        public var bookmark: Data?
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
        /// The subject it was filed in before being put back, if it was.
        public var previousSubjectID: UUID?
        /// The folder Folio wasn't allowed to move it out of, if that's why it's waiting.
        public var blockedFolderPath: String?

        public init(
            id: UUID = UUID(),
            name: String,
            url: URL,
            bookmark: Data?,
            question: String,
            suggestions: [UUID],
            reasons: [String],
            facets: Facets,
            contentHash: String?,
            detail: String,
            embedding: TextEmbedder.Embedding?,
            addedAt: Date = .now,
            previousSubjectID: UUID? = nil,
            blockedFolder: URL? = nil
        ) {
            self.id = id
            self.name = name
            self.path = url.path(percentEncoded: false)
            self.bookmark = bookmark
            self.question = question
            self.suggestions = suggestions
            self.reasons = reasons
            self.documentType = facets.documentType
            self.year = facets.year
            self.exam = facets.exam
            self.contentHash = contentHash
            self.detail = detail
            self.vector = embedding.map { VectorCoding.data(from: $0.vector) }
            self.vectorModel = embedding?.model
            self.addedAt = addedAt
            self.previousSubjectID = previousSubjectID
            self.blockedFolderPath = blockedFolder?.path(percentEncoded: false)
        }

        public var facets: Facets {
            Facets(documentType: documentType, year: year, exam: exam)
        }

        public var url: URL { URL(filePath: path) }

        public var embedding: TextEmbedder.Embedding? {
            VectorCoding.embedding(vector, model: vectorModel)
        }
    }

    /// A file the student filed or already had, kept as an embedding so new
    /// files can be compared with it.
    @Model public final class LearnedExample {
        public enum Source: String, Codable, Sendable {
            /// Already in a subject folder when Folio was set up.
            case existing
            /// The student chose its subject under "Needs a look".
            case choice
            /// The student put it back and filed it somewhere else.
            case correction
        }

        @Attribute(.unique) public var id: UUID
        public var subjectID: UUID
        public var name: String
        public var path: String
        public var vector: Data
        public var model: String
        public var sourceName: String
        public var addedAt: Date
        /// The filed item it came from, so it can be forgotten if that's undone.
        public var itemID: UUID?

        public init(id: UUID = UUID(), subjectID: UUID, name: String, path: String, embedding: TextEmbedder.Embedding, source: Source, addedAt: Date = .now, itemID: UUID? = nil) {
            self.id = id
            self.subjectID = subjectID
            self.name = name
            self.path = path
            self.vector = VectorCoding.data(from: embedding.vector)
            self.model = embedding.model
            self.sourceName = source.rawValue
            self.addedAt = addedAt
            self.itemID = itemID
        }

        public var source: Source? { Source(rawValue: sourceName) }

        public var example: ExampleIndex.Example {
            ExampleIndex.Example(id: id, subjectID: subjectID, name: name, embedding: TextEmbedder.Embedding(vector: VectorCoding.vector(from: vector), model: model))
        }
    }
}

public typealias JournalEntry = FolioSchemaV1.JournalEntry
public typealias ReviewEntry = FolioSchemaV1.ReviewEntry
public typealias LearnedExample = FolioSchemaV1.LearnedExample

/// Stores vectors compactly: 512 numbers take 2 KB.
enum VectorCoding {
    static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(from data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func embedding(_ data: Data?, model: String?) -> TextEmbedder.Embedding? {
        guard let data, let model else { return nil }
        return TextEmbedder.Embedding(vector: vector(from: data), model: model)
    }
}
