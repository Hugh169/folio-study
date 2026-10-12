import Foundation
import SwiftData
import Testing
@testable import FolioKit

@MainActor
struct StoreMigrationTests {
    @Test func aStoreFromFolio01OpensWithNothingLost() throws {
        let temp = try TemporaryFolder()
        let url = temp.url.appending(path: "Support/Folio.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let subject = UUID()
        let itemID = UUID()

        // Save records exactly as Folio 0.1 did, with only the version 1 schema.
        do {
            let schema = Schema(versionedSchema: FolioSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(FolioSchemaV1.FiledItem(
                id: itemID,
                name: "2023 HSC Modern History.pdf",
                subjectID: subject,
                relativePath: "History/Past Papers/2023 HSC Modern History.pdf",
                originalPath: "/Users/student/Downloads/2023 HSC Modern History.pdf",
                facets: Facets(documentType: "Past Papers", year: 2023, exam: "HSC"),
                contentHash: "abc",
                detail: "Past Papers · HSC 2023 · 12 pages",
                reasons: ["Found “Modern History”"],
                chosenByStudent: false
            ))
            context.insert(ReviewEntry(
                name: "Untitled.pdf",
                url: URL(filePath: "/Users/student/Desktop/Untitled.pdf"),
                bookmark: nil,
                question: "Which subject should this go to?",
                suggestions: [subject],
                reasons: [],
                facets: Facets(),
                contentHash: "def",
                detail: "",
                embedding: nil
            ))
            try context.save()
        }

        let store = try FolioStore(url: url)

        #expect(store.filedItems().map(\.id) == [itemID])
        #expect(store.filedItems().first?.facets.year == 2023)
        #expect(store.reviewEntries().map(\.name) == ["Untitled.pdf"])

        // The new planner records work alongside the old ones.
        let session = StudySession(subjectID: subject, start: .now, end: .now.addingTimeInterval(3600))
        store.replaceSessions(with: [session])
        store.insert(AssessmentRecord(Assessment(title: "Essay", subjectID: subject, due: .now.addingTimeInterval(86_400))))
        store.save()
        let reopened = try FolioStore(url: url)
        #expect(reopened.plannedSessions().map(\.id) == [session.id])
        #expect(reopened.assessmentRecords().map(\.title) == ["Essay"])
        #expect(reopened.filedItems().count == 1)
    }

    @Test func aStoreFromFolio04TurnsDeadlinesIntoAssessments() throws {
        let temp = try TemporaryFolder()
        let url = temp.url.appending(path: "Support/Folio.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let subject = UUID()
        let itemID = UUID()
        let sessionID = UUID()
        let openID = UUID()
        let doneID = UUID()
        let due = Date(timeIntervalSinceReferenceDate: 815_000_000)

        // Save records exactly as Folio 0.4 did, with only the version 2 schema.
        do {
            let schema = Schema(versionedSchema: FolioSchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(FolioSchemaV1.FiledItem(
                id: itemID, name: "Task 2 notification.pdf", subjectID: subject,
                relativePath: "Biology/Assessments/Task 2 notification.pdf", originalPath: "/Users/student/Downloads/Task 2 notification.pdf",
                facets: Facets(documentType: "Assessments"), contentHash: "abc", detail: "Assessments · 2 pages", reasons: [], chosenByStudent: false
            ))
            context.insert(FolioSchemaV2.PlannedSession(id: sessionID, subjectID: subject, start: due.addingTimeInterval(-86_400), end: due.addingTimeInterval(-82_800)))
            context.insert(FolioSchemaV2.DeadlineRecord(id: openID, title: "Depth Study", subjectID: subject, due: due, reminderID: "R1", sourcePath: "/Users/student/Downloads/Task 2 notification.pdf"))
            context.insert(FolioSchemaV2.DeadlineRecord(id: doneID, title: "Topic test", subjectID: subject, due: due.addingTimeInterval(-604_800), isDone: true))
            try context.save()
        }

        let store = try FolioStore(url: url)
        let assessments = Dictionary(uniqueKeysWithValues: store.assessmentRecords().map { ($0.id, $0) })
        let open = try #require(assessments[openID])
        #expect(open.assessment.kind == .task)
        #expect(open.assessment.status == .notStarted)
        #expect(open.assessment.source == .file)
        #expect(open.reminderID == "R1")
        #expect(assessments[doneID]?.assessment.status == .submitted)
        #expect(store.plannedSessions().map(\.session.id) == [sessionID])
        #expect(store.plannedSessions().first?.assessmentID == nil)
        #expect(store.filedItems().map(\.id) == [itemID])

        // The new fields work and last.
        var updated = open.assessment
        updated.weighting = 25
        updated.status = .inProgress
        updated.milestones = [Assessment.Milestone(title: "Draft", date: due.addingTimeInterval(-432_000))]
        updated.mark = Assessment.Mark(score: 18, outOf: 25)
        open.update(from: updated)
        store.link(itemID, to: openID, role: .taskSheet)
        store.save()
        let reopened = try FolioStore(url: url)
        let saved = try #require(reopened.assessmentRecord(openID)?.assessment)
        #expect(saved.weighting == 25)
        #expect(saved.status == .inProgress)
        #expect(saved.milestones.map(\.title) == ["Draft"])
        #expect(saved.mark?.fraction == 0.72)
        #expect(reopened.filedItems(linkedTo: openID).map(\.id) == [itemID])
        #expect(reopened.filedItems(linkedTo: openID).first?.fileRole == .taskSheet)
    }

    @Test func aStoreFromFolio05GainsTheStudyTools() throws {
        let temp = try TemporaryFolder()
        let url = temp.url.appending(path: "Support/Folio.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let subject = UUID()
        let sessionID = UUID()
        let assessment = Assessment(title: "Depth Study", subjectID: subject, due: Date(timeIntervalSinceReferenceDate: 815_000_000), weighting: 30)

        // Save records exactly as Folio 0.5 did, with only the version 3 schema.
        do {
            let schema = Schema(versionedSchema: FolioSchemaV3.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(FolioSchemaV3.PlannedSession(id: sessionID, subjectID: subject, start: .now, end: .now.addingTimeInterval(3600), assessmentID: assessment.id, title: "Depth Study: Draft", doneMinutes: 45))
            context.insert(FolioSchemaV3.DeadlineRecord(assessment))
            try context.save()
        }

        let store = try FolioStore(url: url)
        let session = try #require(store.plannedSessions().first?.session)
        #expect(session.id == sessionID)
        #expect(session.title == "Depth Study: Draft")
        #expect(session.doneMinutes == 45)
        #expect(session.outcome == nil)
        #expect(store.assessmentRecords().first?.assessment.weighting == 30)

        // The new records work and last.
        var finished = session
        finished.outcome = .done
        finished.note = "Finished the method"
        store.replaceSessions(with: [finished])
        store.save([Flashcard(subjectID: subject, question: "What is a depth study?", answer: "An investigation", origin: .student)])
        store.save(PracticeAttempt(subjectID: subject, paperName: "2023-hsc-physics.pdf", minutes: 180))
        store.index(path: "Physics/Notes/Forces.pdf", modified: nil, text: "Forces and motion", embedding: TextEmbedder.Embedding(vector: [1, 2], model: "test"))
        store.save()
        let reopened = try FolioStore(url: url)
        #expect(reopened.plannedSessions().first?.session.outcome == .done)
        #expect(reopened.plannedSessions().first?.session.note == "Finished the method")
        #expect(reopened.flashcardRecords().map(\.question) == ["What is a depth study?"])
        #expect(reopened.practiceRecords().first?.attempt.minutes == 180)
        #expect(reopened.indexedFiles().first?.embedding?.vector == [1, 2])

        // Indexing a path again replaces it, and files that have gone are forgotten.
        reopened.index(path: "Physics/Notes/Forces.pdf", modified: nil, text: "Newton's laws", embedding: nil)
        reopened.save()
        #expect(reopened.indexedFiles().map(\.text) == ["Newton's laws"])
        reopened.removeIndexed(["Physics/Notes/Forces.pdf"])
        #expect(reopened.indexedFiles().isEmpty)
    }

    @Test func aStoreFromFolio07GainsPlansAndTodos() throws {
        let temp = try TemporaryFolder()
        let url = temp.url.appending(path: "Support/Folio.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let subject = UUID()
        let sessionID = UUID()
        var assessment = Assessment(title: "Trial exam", subjectID: subject, kind: .exam, due: Date(timeIntervalSinceReferenceDate: 815_000_000), weighting: 30)
        assessment.mark = Assessment.Mark(score: 41, outOf: 50)

        // Save records exactly as Folio 0.7 did, with only the version 4 schema.
        do {
            let schema = Schema(versionedSchema: FolioSchemaV4.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let session = FolioSchemaV4.PlannedSession(id: sessionID, subjectID: subject, start: .now, end: .now.addingTimeInterval(3600), title: "Trial exam")
            session.outcomeName = "partly"
            session.note = "Got to question 5"
            context.insert(session)
            context.insert(FolioSchemaV3.DeadlineRecord(assessment))
            context.insert(FolioSchemaV4.FlashcardRecord(Flashcard(subjectID: subject, question: "q", answer: "a")))
            try context.save()
        }

        let store = try FolioStore(url: url)
        let session = try #require(store.plannedSessions().first?.session)
        #expect(session.id == sessionID)
        #expect(session.outcome == .partly)
        #expect(session.note == "Got to question 5")
        #expect(session.plan.isEmpty)
        #expect(!session.isOwn)
        let saved = try #require(store.assessmentRecords().first?.assessment)
        #expect(saved.mark?.score == 41)
        #expect(saved.markedAt == nil)
        #expect(saved.planFrom == nil)
        #expect(store.flashcardRecords().count == 1)

        // The new fields and records work and last.
        var planned = session
        planned.plan = [PlanStep(title: "Questions 21 to 25"), PlanStep(title: "Review 8 cards", isDone: true, kind: .cards)]
        planned.isOwn = true
        store.replaceSessions(with: [planned])
        var changed = saved
        changed.markedAt = Date(timeIntervalSinceReferenceDate: 815_500_000)
        changed.planFrom = Date(timeIntervalSinceReferenceDate: 814_000_000)
        store.assessmentRecords().first?.update(from: changed)
        store.save(Todo(subjectID: subject, title: "Ask about question 7", minutes: 10))
        store.save()

        let reopened = try FolioStore(url: url)
        let again = try #require(reopened.plannedSessions().first?.session)
        #expect(again.plan == planned.plan)
        #expect(again.isOwn)
        #expect(reopened.assessmentRecords().first?.assessment.markedAt == changed.markedAt)
        #expect(reopened.assessmentRecords().first?.assessment.planFrom == changed.planFrom)
        #expect(reopened.todoRecords().map(\.todo.title) == ["Ask about question 7"])
        #expect(reopened.todoRecords().first?.todo.minutes == 10)
    }

    @Test func todosAreSavedChangedAndDeleted() throws {
        let store = try FolioStore(url: nil)
        var todo = Todo(subjectID: UUID(), title: "Copy up notes")
        store.save(todo)
        todo.isDone = true
        todo.doneAt = .now
        store.save(todo)
        #expect(store.todoRecords().count == 1)
        #expect(store.todoRecords().first?.todo.isDone == true)
        store.deleteTodo(todo.id)
        #expect(store.todoRecords().isEmpty)
    }

    @Test func flashcardsAreSavedAndDeleted() throws {
        let store = try FolioStore(url: nil)
        let subject = UUID()
        var card = Flashcard(subjectID: subject, question: "q", answer: "a")
        store.save([card])
        card = card.answered(knewIt: true, at: .now, calendar: .current)
        store.save([card])
        #expect(store.flashcardRecords().count == 1)
        #expect(store.flashcardRecords().first?.box == 2)
        store.deleteFlashcards([card.id])
        #expect(store.flashcardRecords().isEmpty)
    }

    @Test func replacingSessionsUpdatesAddsAndRemoves() throws {
        let store = try FolioStore(url: nil)
        let subject = UUID()
        let keep = StudySession(subjectID: subject, start: .now, end: .now.addingTimeInterval(3600))
        let drop = StudySession(subjectID: subject, start: .now.addingTimeInterval(7200), end: .now.addingTimeInterval(10_800))
        store.replaceSessions(with: [keep, drop])

        var moved = keep
        moved.start = moved.start.addingTimeInterval(1800)
        let added = StudySession(subjectID: subject, start: .now.addingTimeInterval(86_400), end: .now.addingTimeInterval(90_000))
        store.replaceSessions(with: [moved, added])

        let saved = store.plannedSessions()
        #expect(Set(saved.map(\.id)) == [keep.id, added.id])
        #expect(saved.first { $0.id == keep.id }?.start == moved.start)
    }
}
