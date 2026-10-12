import Foundation
import SwiftData

/// Version 5 adds what the student means to do in each study session and
/// which sessions they made themselves, a to-do list for each subject, and
/// for assessments the day a mark came back and a chosen day to start work.
/// Every new field is optional and to-dos are a new kind of record, so stores
/// from version 4 carry over by themselves.
public enum FolioSchemaV5: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            FolioSchemaV3.FiledItem.self, FolioSchemaV1.JournalEntry.self, FolioSchemaV1.ReviewEntry.self, FolioSchemaV1.LearnedExample.self,
            PlannedSession.self, DeadlineRecord.self, FolioSchemaV4.FlashcardRecord.self, FolioSchemaV4.PracticeRecord.self,
            FolioSchemaV4.IndexedFile.self, TodoRecord.self,
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
        /// The steps of its plan, as JSON.
        public var planData: Data?
        /// Made or changed by the student.
        public var isOwn: Bool?

        public init(id: UUID = UUID(), subjectID: UUID, start: Date, end: Date) {
            self.id = id
            self.subjectID = subjectID
            self.start = start
            self.end = end
        }

        public convenience init(_ session: StudySession) {
            self.init(id: session.id, subjectID: session.subjectID, start: session.start, end: session.end)
            update(from: session)
        }

        public var session: StudySession {
            StudySession(
                id: id, subjectID: subjectID, start: start, end: end, assessmentID: assessmentID, title: title, doneMinutes: doneMinutes,
                outcome: outcomeName.flatMap(StudySession.Outcome.init(rawValue:)), note: note,
                plan: planData.flatMap { try? JSONDecoder().decode([PlanStep].self, from: $0) } ?? [],
                isOwn: isOwn ?? false
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
            planData = session.plan.isEmpty ? nil : try? JSONEncoder().encode(session.plan)
            isOwn = session.isOwn ? true : nil
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
        public var markedAt: Date?
        public var planFrom: Date?

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
                externalID: externalID,
                markedAt: markedAt,
                planFrom: planFrom
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
            markedAt = assessment.markedAt
            planFrom = assessment.planFrom
        }
    }

    /// Something to do for a subject.
    @Model public final class TodoRecord {
        @Attribute(.unique) public var id: UUID
        public var subjectID: UUID
        public var title: String
        public var assessmentID: UUID?
        public var minutes: Int?
        public var isDone: Bool
        public var createdAt: Date
        public var doneAt: Date?

        public init(_ todo: Todo) {
            id = todo.id
            subjectID = todo.subjectID
            title = todo.title
            isDone = todo.isDone
            createdAt = todo.createdAt
            update(from: todo)
        }

        public var todo: Todo {
            Todo(id: id, subjectID: subjectID, title: title, assessmentID: assessmentID, minutes: minutes, isDone: isDone, createdAt: createdAt, doneAt: doneAt)
        }

        public func update(from todo: Todo) {
            subjectID = todo.subjectID
            title = todo.title
            assessmentID = todo.assessmentID
            minutes = todo.minutes
            isDone = todo.isDone
            doneAt = todo.doneAt
        }
    }
}

public typealias PlannedSession = FolioSchemaV5.PlannedSession
public typealias AssessmentRecord = FolioSchemaV5.DeadlineRecord
public typealias TodoRecord = FolioSchemaV5.TodoRecord
