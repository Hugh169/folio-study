import Foundation
import SwiftData

/// Version 3 turns deadlines into assessments, links study sessions and filed
/// files to them, and records the minutes actually studied. Every new field is
/// optional, so stores from version 2 carry over by themselves.
///
/// `DeadlineRecord` keeps its version 2 name so its records carry over too;
/// in code it's `AssessmentRecord`.
public enum FolioSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [FiledItem.self, FolioSchemaV1.JournalEntry.self, FolioSchemaV1.ReviewEntry.self, FolioSchemaV1.LearnedExample.self, PlannedSession.self, DeadlineRecord.self]
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
        /// The assessment it belongs to, such as the task it's a draft of.
        public var assessmentID: UUID?
        /// What it is to that assessment: a `FileRole` raw value.
        public var fileRoleName: String?

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

        public var fileRole: FileRole? {
            get { fileRoleName.flatMap(FileRole.init(rawValue:)) }
            set { fileRoleName = newValue?.rawValue }
        }
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
            self.init(id: session.id, subjectID: session.subjectID, start: session.start, end: session.end, assessmentID: session.assessmentID, title: session.title, doneMinutes: session.doneMinutes)
        }

        public var session: StudySession {
            StudySession(id: id, subjectID: subjectID, start: start, end: end, assessmentID: assessmentID, title: title, doneMinutes: doneMinutes)
        }

        public func update(from session: StudySession) {
            subjectID = session.subjectID
            start = session.start
            end = session.end
            assessmentID = session.assessmentID
            title = session.title
            doneMinutes = session.doneMinutes
        }
    }

    /// An assessment: a task, exam or test. Named for the deadlines of version 2.
    @Model public final class DeadlineRecord {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var subjectID: UUID
        public var due: Date
        /// Submitted or marked; kept in step with `statusName`.
        public var isDone: Bool
        /// The matching reminder in Apple Reminders, when Folio added one.
        public var reminderID: String?
        /// The file it was found in, if any.
        public var sourcePath: String?
        public var createdAt: Date
        public var kindName: String?
        public var statusName: String?
        public var lengthMinutes: Int?
        public var room: String?
        public var weighting: Double?
        public var totalMarks: Double?
        public var markScore: Double?
        public var markOutOf: Double?
        public var markGrade: String?
        public var feedback: String?
        public var notes: String?
        public var estimateHours: Double?
        /// The milestones, as JSON.
        public var milestonesData: Data?
        public var sourceName: String?
        public var externalID: String?

        public init(id: UUID = UUID(), title: String, subjectID: UUID, due: Date, isDone: Bool = false, reminderID: String? = nil, sourcePath: String? = nil, createdAt: Date = .now) {
            self.id = id
            self.title = title
            self.subjectID = subjectID
            self.due = due
            self.isDone = isDone
            self.reminderID = reminderID
            self.sourcePath = sourcePath
            self.createdAt = createdAt
        }

        public convenience init(_ assessment: Assessment, reminderID: String? = nil, sourcePath: String? = nil, createdAt: Date = .now) {
            self.init(id: assessment.id, title: assessment.title, subjectID: assessment.subjectID, due: assessment.due, isDone: assessment.isDone, reminderID: reminderID, sourcePath: sourcePath, createdAt: createdAt)
            update(from: assessment)
        }

        public var assessment: Assessment {
            let status = statusName.flatMap(Assessment.Status.init(rawValue:)) ?? (isDone ? .submitted : .notStarted)
            let mark: Assessment.Mark? = markScore == nil && markGrade == nil ? nil : Assessment.Mark(score: markScore, outOf: markOutOf, grade: markGrade)
            return Assessment(
                id: id,
                title: title,
                subjectID: subjectID,
                kind: kindName.flatMap(Assessment.Kind.init(rawValue:)) ?? .task,
                due: due,
                lengthMinutes: lengthMinutes,
                room: room,
                weighting: weighting,
                totalMarks: totalMarks,
                status: status,
                mark: mark,
                feedback: feedback ?? "",
                notes: notes ?? "",
                estimateHours: estimateHours,
                milestones: milestonesData.flatMap { try? JSONDecoder().decode([Assessment.Milestone].self, from: $0) } ?? [],
                source: sourceName.flatMap(Assessment.Source.init(rawValue:)) ?? (sourcePath == nil ? .typed : .file),
                externalID: externalID
            )
        }

        public func update(from assessment: Assessment) {
            title = assessment.title
            subjectID = assessment.subjectID
            due = assessment.due
            isDone = assessment.isDone
            kindName = assessment.kind.rawValue
            statusName = assessment.status.rawValue
            lengthMinutes = assessment.lengthMinutes
            room = assessment.room
            weighting = assessment.weighting
            totalMarks = assessment.totalMarks
            markScore = assessment.mark?.score
            markOutOf = assessment.mark?.outOf
            markGrade = assessment.mark?.grade
            feedback = assessment.feedback.isEmpty ? nil : assessment.feedback
            notes = assessment.notes.isEmpty ? nil : assessment.notes
            estimateHours = assessment.estimateHours
            milestonesData = assessment.milestones.isEmpty ? nil : try? JSONEncoder().encode(assessment.milestones)
            sourceName = assessment.source.rawValue
            externalID = assessment.externalID
        }
    }
}

public typealias FiledItem = FolioSchemaV3.FiledItem
