import Foundation
import Testing
@testable import FolioKit

@MainActor
struct BackupTests {
    let oldLibrary = URL(filePath: "/Users/sam/Documents/School", directoryHint: .isDirectory)
    let newLibrary = URL(filePath: "/Users/sam/Documents/Folio", directoryHint: .isDirectory)
    let profile = Profile.starter()
    var physics: Subject { profile.subjects[2] }

    /// A store with one of everything: a filed file, two waiting files, an
    /// example from the School folder and one from elsewhere, a session, an
    /// assessment the file is linked to, and a move in the Undo history.
    func filledStore() throws -> FolioStore {
        let store = try FolioStore(url: nil)
        let embedding = TextEmbedder.Embedding(vector: [0.25, -0.5, 1], model: "test")
        let item = FiledItem(
            name: "Forces.pdf", subjectID: physics.id, relativePath: "Physics/Notes/Forces.pdf",
            originalPath: "/Users/sam/Downloads/Forces.pdf", facets: Facets(documentType: "Notes", year: 2026),
            contentHash: "abc", detail: "Notes · 2 pages", reasons: ["Found “force”"], chosenByStudent: false, embedding: embedding
        )
        store.insert(item)
        store.insert(JournalEntry(batchID: UUID(), action: .file, from: URL(filePath: "/Users/sam/Downloads/Forces.pdf"), to: oldLibrary.appending(path: "Physics/Notes/Forces.pdf"), itemID: item.id))
        for name in ["here.pdf", "gone.pdf"] {
            store.insert(ReviewEntry(
                name: name, url: URL(filePath: "/Users/sam/Downloads/\(name)"), bookmark: nil, question: "Which subject?",
                suggestions: [physics.id], reasons: [], facets: Facets(), contentHash: name, detail: "", embedding: embedding
            ))
        }
        store.insert(LearnedExample(subjectID: physics.id, name: "Forces.pdf", path: oldLibrary.appending(path: "Physics/Notes/Forces.pdf").path(percentEncoded: false), embedding: embedding, source: .choice, itemID: item.id))
        store.insert(LearnedExample(subjectID: physics.id, name: "Old notes.pdf", path: "/Volumes/USB/Old notes.pdf", embedding: embedding, source: .existing))
        store.insert(PlannedSession(subjectID: physics.id, start: .now, end: .now.addingTimeInterval(3600)))
        var report = Assessment(title: "Prac report", subjectID: physics.id, kind: .practical, due: .now.addingTimeInterval(86400), weighting: 20, status: .inProgress)
        report.milestones = [Assessment.Milestone(title: "Draft", date: .now.addingTimeInterval(3600))]
        store.insert(AssessmentRecord(report, reminderID: "reminder-1"))
        item.assessmentID = report.id
        item.fileRole = .taskSheet
        store.save()
        return store
    }

    @Test func aBackupComesBackIntoAnEmptyStore() throws {
        let original = try filledStore()
        var profile = profile
        profile.studentName = "Sam"
        let preferences = FolioBackup.Preferences(
            calendars: [FolioBackup.CalendarChoice(id: "cal-1", title: "School", account: "iCloud", plansAround: true, isTimetable: true)],
            usesReminders: true, watchesDownloads: true, watchedFolders: ["/Users/sam/Desktop"]
        )
        let data = try FolioBackup(profile: profile, store: original, library: oldLibrary, preferences: preferences).encoded()

        let backup = try FolioBackup.decode(data)
        #expect(backup.profile.studentName == "Sam")
        #expect(backup.preferences == preferences)

        let store = try FolioStore(url: nil)
        let restored = try backup.restore(into: store, library: newLibrary, fileExists: { $0.lastPathComponent == "here.pdf" }) { $0 == "missing" }

        #expect(restored == FolioBackup.Restored(filed: 1, waiting: 1, waitingNotFound: 1, examples: 2, sessions: 1, assessments: 1))
        let item = try #require(store.filedItems().first)
        #expect(item.relativePath == "Physics/Notes/Forces.pdf")
        #expect(item.facets == Facets(documentType: "Notes", year: 2026))
        #expect(item.embedding?.vector == [0.25, -0.5, 1])
        #expect(store.reviewEntries().map(\.name) == ["here.pdf"])
        #expect(store.reviewEntries().first?.embedding?.vector == [0.25, -0.5, 1])
        // Paths in the School folder move to the new one; others stay put.
        let paths = Set(store.examples().map(\.path))
        #expect(paths == ["/Users/sam/Documents/Folio/Physics/Notes/Forces.pdf", "/Volumes/USB/Old notes.pdf"])
        #expect(store.examples().allSatisfy { $0.example.embedding.vector == [0.25, -0.5, 1] })
        #expect(store.plannedSessions().count == 1)
        // A reminder that isn't on this Mac is let go.
        #expect(store.assessmentRecords().first?.reminderID == nil)
        let report = try #require(store.assessmentRecords().first?.assessment)
        #expect(report.title == "Prac report")
        #expect(report.kind == .practical)
        #expect(report.weighting == 20)
        #expect(report.status == .inProgress)
        #expect(report.milestones.map(\.title) == ["Draft"])
        #expect(store.filedItems(linkedTo: report.id).first?.fileRole == .taskSheet)
    }

    @Test func deadlinesInAnOlderBackupComeBackAsTasks() throws {
        let data = try FolioBackup(profile: profile, store: try FolioStore(url: nil), library: oldLibrary, preferences: .init()).encoded()
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 1
        json["assessments"] = nil
        let deadlineID = UUID()
        json["deadlines"] = [[
            "id": deadlineID.uuidString, "title": "Essay", "subjectID": physics.id.uuidString,
            "due": 815_000_000.0, "isDone": true, "createdAt": 814_000_000.0,
        ]]
        let backup = try FolioBackup.decode(try JSONSerialization.data(withJSONObject: json))

        let store = try FolioStore(url: nil)
        let restored = try backup.restore(into: store, library: newLibrary, fileExists: { _ in true })
        #expect(restored.assessments == 1)
        let essay = try #require(store.assessmentRecord(deadlineID)?.assessment)
        #expect(essay.title == "Essay")
        #expect(essay.kind == .task)
        #expect(essay.status == .submitted)
    }

    @Test func restoringReplacesWhatWasThere() throws {
        let store = try filledStore()
        let backup = try FolioBackup.decode(FolioBackup(profile: profile, store: try FolioStore(url: nil), library: oldLibrary, preferences: .init()).encoded())
        try backup.restore(into: store, library: newLibrary, fileExists: { _ in true })
        #expect(store.filedItems().isEmpty)
        #expect(store.reviewEntries().isEmpty)
        #expect(store.examples().isEmpty)
        #expect(store.assessmentRecords().isEmpty)
        #expect(store.knownHashes().isEmpty)
    }

    @Test func flashcardsPractiseAndHowSessionsWentComeBack() throws {
        let original = try filledStore()
        let card = Flashcard(subjectID: physics.id, question: "What is Lenz's law?", answer: "The induced current opposes the change.", sourceName: "Forces.pdf", origin: .onDevice, box: 3, due: .now.addingTimeInterval(86_400), reviewCount: 4, missCount: 1)
        original.save([card])
        let attempt = PracticeAttempt(subjectID: physics.id, paperName: "2023-hsc-physics.pdf", minutes: 170, mark: Assessment.Mark(score: 74, outOf: 100), note: "Module 6 questions were hard")
        original.save(attempt)
        let session = try #require(original.plannedSessions().first)
        var done = session.session
        done.outcome = .partly
        done.doneMinutes = 40
        done.note = "Got to question 5"
        session.update(from: done)
        original.index(path: "Physics/Notes/Forces.pdf", modified: .now, text: "Forces", embedding: nil)
        original.save()

        let backup = try FolioBackup.decode(FolioBackup(profile: profile, store: original, library: oldLibrary, preferences: .init()).encoded())
        let store = try FolioStore(url: nil)
        let restored = try backup.restore(into: store, library: newLibrary, fileExists: { _ in true })

        #expect(restored.flashcards == 1)
        #expect(restored.practice == 1)
        #expect(store.flashcardRecords().map(\.card) == [card])
        #expect(store.practiceRecords().map(\.attempt) == [attempt])
        let saved = try #require(store.plannedSessions().first?.session)
        #expect(saved.outcome == .partly)
        #expect(saved.doneMinutes == 40)
        #expect(saved.note == "Got to question 5")
        // The search index is built again from the files, so it isn't in backups.
        #expect(store.indexedFiles().isEmpty)
    }

    @Test func aVersion2BackupHasNoCardsAndStillRestores() throws {
        let data = try FolioBackup(profile: profile, store: try filledStore(), library: oldLibrary, preferences: .init()).encoded()
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 2
        json["flashcards"] = nil
        json["practice"] = nil
        let backup = try FolioBackup.decode(try JSONSerialization.data(withJSONObject: json))
        let store = try FolioStore(url: nil)
        let restored = try backup.restore(into: store, library: newLibrary, fileExists: { _ in true })
        #expect(restored.flashcards == 0)
        #expect(restored.sessions == 1)
        #expect(store.plannedSessions().first?.session.outcome == nil)
    }

    @Test func todosAndSessionPlansComeBack() throws {
        let original = try filledStore()
        let todo = Todo(subjectID: physics.id, title: "Redo the graph", minutes: 15)
        original.save(todo)
        var session = try #require(original.plannedSessions().first?.session)
        session.plan = [PlanStep(title: "Write the method"), todo.step]
        session.isOwn = true
        original.replaceSessions(with: [session])
        var report = try #require(original.assessmentRecords().first?.assessment)
        report.planFrom = Date(timeIntervalSinceReferenceDate: 814_000_000)
        original.assessmentRecords().first?.update(from: report)
        original.save()

        let backup = try FolioBackup.decode(FolioBackup(profile: profile, store: original, library: oldLibrary, preferences: .init()).encoded())
        #expect(backup.version == 4)
        let store = try FolioStore(url: nil)
        let restored = try backup.restore(into: store, library: newLibrary, fileExists: { _ in true })

        #expect(restored.todos == 1)
        #expect(store.todoRecords().map(\.todo) == [todo])
        let saved = try #require(store.plannedSessions().first?.session)
        #expect(saved.plan == session.plan)
        #expect(saved.isOwn)
        #expect(store.assessmentRecords().first?.assessment.planFrom == report.planFrom)
    }

    @Test func aVersion3BackupHasNoTodosAndStillRestores() throws {
        let data = try FolioBackup(profile: profile, store: try filledStore(), library: oldLibrary, preferences: .init()).encoded()
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 3
        json["todos"] = nil
        // Version 3 sessions had no plans.
        json["sessions"] = (json["sessions"] as? [[String: Any]])?.map { session in
            var session = session
            session["plan"] = nil
            session["isOwn"] = nil
            return session
        }
        let backup = try FolioBackup.decode(try JSONSerialization.data(withJSONObject: json))
        let store = try FolioStore(url: nil)
        let restored = try backup.restore(into: store, library: newLibrary, fileExists: { _ in true })
        #expect(restored.todos == 0)
        #expect(restored.sessions == 1)
        #expect(store.plannedSessions().first?.session.plan.isEmpty == true)
    }

    @Test func anAssessmentFromAnUnknownSourceStillComesBack() throws {
        let data = try FolioBackup(profile: profile, store: try filledStore(), library: oldLibrary, preferences: .init()).encoded()
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(json["assessments"] as? [[String: Any]])
        var assessment = try #require(entries[0]["assessment"] as? [String: Any])
        // Saved by a test build that synced Google Classroom, which Folio no longer has.
        assessment["source"] = "classroom"
        entries[0]["assessment"] = assessment
        json["assessments"] = entries
        let backup = try FolioBackup.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(backup.allAssessments.first?.assessment.source == .typed)
        #expect(backup.allAssessments.first?.assessment.title == "Prac report")
    }

    @Test func backupsFromANewerFolioAreRefused() throws {
        var backup = try FolioBackup.decode(FolioBackup(profile: profile, store: try FolioStore(url: nil), library: oldLibrary, preferences: .init()).encoded())
        backup.version = FolioBackup.currentVersion + 1
        #expect(throws: FolioBackup.BackupError.newerVersion(FolioBackup.currentVersion + 1)) {
            try FolioBackup.decode(try backup.encoded())
        }
    }

    @Test func theUndoHistoryIsLeftBehind() throws {
        let store = try filledStore()
        let itemID = try #require(store.filedItems().first?.id)
        #expect(!store.journal(for: itemID).isEmpty)
        let backup = FolioBackup(profile: profile, store: store, library: oldLibrary, preferences: .init())
        try backup.restore(into: store, library: newLibrary, fileExists: { _ in true })
        #expect(store.journal(for: itemID).isEmpty)
        #expect(store.filedItems().first?.id == itemID)
    }
}
