import Foundation
import SwiftData

/// Version 4 adds the study tools: flashcards, past papers the student
/// practised, how each study session went, and what's in each file in the
/// library, for searching. Sessions only gain optional fields and the rest are
/// new kinds of record, so stores from version 3 carry over by themselves.
public enum FolioSchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            FolioSchemaV3.FiledItem.self, FolioSchemaV1.JournalEntry.self, FolioSchemaV1.ReviewEntry.self, FolioSchemaV1.LearnedExample.self,
            PlannedSession.self, FolioSchemaV3.DeadlineRecord.self, FlashcardRecord.self, PracticeRecord.self, IndexedFile.self,
        ]
    }

    /// A study session in the planner.
    @Model public final class PlannedSession {
        @Attribute(.unique) public var id: UUID
        public var subjectID: UUID
        public var start: Date
        public var end: Date
        public var assessmentID: UUID?
        public var title: String?
        public var doneMinutes: Int?
        /// How it went: a `StudySession.Outcome` raw value.
        public var outcomeName: String?
        public var note: String?

        public init(id: UUID = UUID(), subjectID: UUID, start: Date, end: Date, assessmentID: UUID? = nil, title: String? = nil, doneMinutes: Int? = nil) {
            self.id = id
            self.subjectID = subjectID
            self.start = start
            self.end = end
            self.assessmentID = assessmentID
            self.title = title
            self.doneMinutes = doneMinutes
        }

        public convenience init(_ session: StudySession) {
            self.init(id: session.id, subjectID: session.subjectID, start: session.start, end: session.end)
            update(from: session)
        }

        public var session: StudySession {
            StudySession(
                id: id, subjectID: subjectID, start: start, end: end, assessmentID: assessmentID, title: title, doneMinutes: doneMinutes,
                outcome: outcomeName.flatMap(StudySession.Outcome.init(rawValue:)), note: note
            )
        }

        public func update(from session: StudySession) {
            subjectID = session.subjectID
            start = session.start
            end = session.end
            assessmentID = session.assessmentID
            title = session.title
            doneMinutes = session.doneMinutes
            outcomeName = session.outcome?.rawValue
            note = session.note
        }
    }

    /// A flashcard and where it is in its Leitner schedule.
    @Model public final class FlashcardRecord {
        @Attribute(.unique) public var id: UUID
        public var subjectID: UUID
        public var question: String
        public var answer: String
        public var sourceID: UUID?
        public var sourceName: String?
        public var quote: String?
        public var assessmentID: UUID?
        public var originName: String
        public var box: Int
        public var due: Date
        public var createdAt: Date
        public var reviewedAt: Date?
        public var reviewCount: Int
        public var missCount: Int

        public init(_ card: Flashcard) {
            id = card.id
            subjectID = card.subjectID
            question = card.question
            answer = card.answer
            originName = card.origin.rawValue
            box = card.box
            due = card.due
            createdAt = card.createdAt
            reviewCount = card.reviewCount
            missCount = card.missCount
            update(from: card)
        }

        public var card: Flashcard {
            Flashcard(
                id: id, subjectID: subjectID, question: question, answer: answer, sourceID: sourceID, sourceName: sourceName, quote: quote,
                assessmentID: assessmentID, origin: Flashcard.Origin(rawValue: originName) ?? .student, box: box, due: due,
                createdAt: createdAt, reviewedAt: reviewedAt, reviewCount: reviewCount, missCount: missCount
            )
        }

        public func update(from card: Flashcard) {
            subjectID = card.subjectID
            question = card.question
            answer = card.answer
            sourceID = card.sourceID
            sourceName = card.sourceName
            quote = card.quote
            assessmentID = card.assessmentID
            originName = card.origin.rawValue
            box = card.box
            due = card.due
            reviewedAt = card.reviewedAt
            reviewCount = card.reviewCount
            missCount = card.missCount
        }
    }

    /// A past paper the student practised.
    @Model public final class PracticeRecord {
        @Attribute(.unique) public var id: UUID
        public var subjectID: UUID
        public var paperName: String
        public var paperID: UUID?
        public var date: Date
        public var minutes: Int
        public var markScore: Double?
        public var markOutOf: Double?
        public var markGrade: String?
        public var note: String

        public init(_ attempt: PracticeAttempt) {
            id = attempt.id
            subjectID = attempt.subjectID
            paperName = attempt.paperName
            paperID = attempt.paperID
            date = attempt.date
            minutes = attempt.minutes
            note = attempt.note
            update(from: attempt)
        }

        public var attempt: PracticeAttempt {
            let mark: Assessment.Mark? = markScore == nil && markGrade == nil ? nil : Assessment.Mark(score: markScore, outOf: markOutOf, grade: markGrade)
            return PracticeAttempt(id: id, subjectID: subjectID, paperName: paperName, paperID: paperID, date: date, minutes: minutes, mark: mark, note: note)
        }

        public func update(from attempt: PracticeAttempt) {
            subjectID = attempt.subjectID
            paperName = attempt.paperName
            paperID = attempt.paperID
            date = attempt.date
            minutes = attempt.minutes
            markScore = attempt.mark?.score
            markOutOf = attempt.mark?.outOf
            markGrade = attempt.mark?.grade
            note = attempt.note
        }
    }

    /// What's in a file in the library, for searching: the text Folio read
    /// from it and its embedding. It can always be read again, so backups
    /// leave it out.
    @Model public final class IndexedFile {
        public var id: UUID
        /// Where it is inside the library, such as "History/Notes/Weimar.docx".
        @Attribute(.unique) public var path: String
        /// The file's modification date when it was read, so a changed file is read again.
        public var modified: Date?
        public var text: String
        public var vector: Data?
        public var vectorModel: String?
        public var indexedAt: Date

        public init(id: UUID = UUID(), path: String, modified: Date?, text: String, embedding: TextEmbedder.Embedding?, indexedAt: Date = .now) {
            self.id = id
            self.path = path
            self.modified = modified
            self.text = text
            self.vector = embedding.map { VectorCoding.data(from: $0.vector) }
            self.vectorModel = embedding?.model
            self.indexedAt = indexedAt
        }

        public var embedding: TextEmbedder.Embedding? {
            VectorCoding.embedding(vector, model: vectorModel)
        }
    }
}

public typealias FlashcardRecord = FolioSchemaV4.FlashcardRecord
public typealias PracticeRecord = FolioSchemaV4.PracticeRecord
public typealias IndexedFile = FolioSchemaV4.IndexedFile
