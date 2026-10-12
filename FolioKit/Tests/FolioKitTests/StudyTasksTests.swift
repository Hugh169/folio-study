import Foundation
import Testing
@testable import FolioKit

/// Plans inside study sessions, sessions the student makes, and to-dos.
struct StudyTasksTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        calendar.firstWeekday = 2
        return calendar
    }()
    let subjects = Profile.starter().subjects

    /// Monday 5 October 2026.
    var monday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
    }

    func date(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: monday)!
    }

    var planner: WeekPlanner { WeekPlanner(calendar: calendar) }

    // MARK: Steps

    @Test func sessionsSavedBeforePlansStillLoad() throws {
        let json = #"{"id":"6C1E2A55-1B7B-4F51-9D0F-3D6C0A1F2E11","subjectID":"0B9D3F0E-5D8A-4C51-8E8B-2A1F4C6D7E99","start":800000000,"end":800003600,"title":"Essay"}"#
        let session = try JSONDecoder().decode(StudySession.self, from: Data(json.utf8))
        #expect(session.title == "Essay")
        #expect(session.plan.isEmpty)
        #expect(!session.isOwn)
        #expect(session.minutes == 60)
    }

    @Test func aStepOfAKindFromANewerFolioReadsAsTheStudentsOwn() throws {
        let json = #"{"id":"6C1E2A55-1B7B-4F51-9D0F-3D6C0A1F2E11","title":"Watch the lecture","isDone":false,"kind":"video"}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        #expect(step.kind == .own)
        #expect(step.title == "Watch the lecture")
    }

    @Test func theSameStepIsntAddedTwice() {
        let todo = Todo(subjectID: subjects[0].id, title: "Find three quotes")
        var plan = [PlanStep(title: "Review 3 cards", kind: .cards), todo.step, PlanStep(title: "Write the intro")]
        plan.add([
            PlanStep(title: "Review 5 cards", kind: .cards),
            todo.step,
            PlanStep(title: " write the intro "),
            PlanStep(title: "Write the conclusion"),
        ])
        #expect(plan.map(\.title) == ["Review 3 cards", "Find three quotes", "Write the intro", "Write the conclusion"])
    }

    // MARK: Plan My Week

    @Test func ownSessionsStayAndNewOnesGoAroundThem() {
        let english = subjects[0]
        let own = StudySession(subjectID: english.id, start: date(day: 1, 16), end: date(day: 1, 17, 30), isOwn: true)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [], existing: [own])

        #expect(result.sessions.contains(own))
        let others = result.sessions.filter { $0.id != own.id }
        #expect(!others.isEmpty)
        let gap: TimeInterval = 30 * 60
        for session in others where calendar.isDate(session.start, inSameDayAs: own.start) {
            #expect(session.end.addingTimeInterval(gap) <= own.start || session.start >= own.end.addingTimeInterval(gap))
        }
        // English already has its general session this week.
        #expect(!others.contains { $0.subjectID == english.id })
    }

    @Test func ownSessionsCountTowardsTheirAssessment() {
        let maths = subjects[1]
        let task = Assessment(title: "Investigation", subjectID: maths.id, due: date(day: 6, 9), estimateHours: 6)
        let minutes = { (sessions: [StudySession]) in sessions.filter { $0.assessmentID == task.id }.reduce(0) { $0 + $1.minutes } }
        let without = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [task], existing: [])

        let own = StudySession(subjectID: maths.id, start: date(day: 2, 16), end: date(day: 2, 18), assessmentID: task.id, isOwn: true)
        let with = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [task], existing: [own])
        let added = with.sessions.filter { $0.id != own.id }

        #expect(minutes(added) < minutes(without.sessions))
        #expect(minutes(added) + own.minutes <= minutes(without.sessions) + 60)
    }

    @Test func todosGoIntoTheSubjectsSessions() {
        let physics = subjects[2]
        let report = Assessment(title: "Prac report", subjectID: physics.id, due: date(day: 5, 9), estimateHours: 2)
        let graph = Todo(subjectID: physics.id, title: "Redo the graph", assessmentID: report.id, createdAt: date(day: -2, 9))
        let notes = Todo(subjectID: physics.id, title: "Copy up Tuesday's notes", createdAt: date(day: -1, 9))
        let old = Todo(subjectID: physics.id, title: "Already done", isDone: true)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [report], existing: [], todos: [graph, notes, old])

        let reportSessions = result.sessions.filter { $0.assessmentID == report.id }.sorted { $0.start < $1.start }
        #expect(reportSessions.first?.plan.map(\.title) == ["Redo the graph"])
        #expect(reportSessions.first?.plan.first?.kind == .todo)
        let general = result.sessions.filter { $0.subjectID == physics.id && $0.assessmentID == nil }
        #expect(general.flatMap(\.plan).map(\.title) == ["Copy up Tuesday's notes"])
        #expect(!result.sessions.flatMap(\.plan).contains { $0.title == "Already done" })
    }

    @Test func moreTodosThanFitGetAnotherSession() {
        let english = subjects[0]
        let todos = (1...4).map { Todo(subjectID: english.id, title: "Job \($0)", minutes: 30, createdAt: date(day: -1, $0)) }
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [], existing: [], todos: todos)

        let general = result.sessions.filter { $0.subjectID == english.id }
        #expect(general.count == 2)
        #expect(general.flatMap(\.plan).map(\.title).sorted() == ["Job 1", "Job 2", "Job 3", "Job 4"])
        #expect(general.allSatisfy { $0.plan.count == 2 })
    }

    @Test func todosWaitForTheStudentsOwnSession() {
        let english = subjects[0]
        let own = StudySession(subjectID: english.id, start: date(day: 2, 16), end: date(day: 2, 17), isOwn: true)
        let todo = Todo(subjectID: english.id, title: "Find three quotes")
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [], existing: [own], todos: [todo])
        // No extra session: the student made their own, where Folio suggests the to-do.
        #expect(result.sessions.filter { $0.subjectID == english.id }.map(\.id) == [own.id])
        #expect(result.sessions.flatMap(\.plan).isEmpty)
    }

    @Test func stepsFromReplacedSessionsMoveToTheNewPlan() {
        let english = subjects[0]
        let essay = Assessment(title: "Essay", subjectID: english.id, due: date(day: 5, 9), estimateHours: 3)
        var old = StudySession(subjectID: english.id, start: date(day: 2, 16), end: date(day: 2, 17), assessmentID: essay.id, title: "Essay")
        old.plan = [PlanStep(title: "Finish paragraph 3"), PlanStep(title: "Review 2 cards", kind: .cards)]
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [essay], existing: [old])

        #expect(!result.sessions.contains { $0.id == old.id })
        #expect(result.sessions.filter { $0.assessmentID == essay.id }.flatMap(\.plan).map(\.title) == ["Finish paragraph 3"])
        #expect(result.leftoverSteps.isEmpty)

        // With no time for it this week, the step comes back so it isn't lost.
        let empty = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: [], assessments: [], existing: [old])
        #expect(empty.leftoverSteps.map(\.step.title) == ["Finish paragraph 3"])
        #expect(empty.leftoverSteps.first?.subjectID == english.id)
    }

    @Test func aChosenStartDayBringsWorkForward() {
        let english = subjects[0]
        var task = Assessment(title: "Major work", subjectID: english.id, due: date(day: 35, 9), estimateHours: 12)
        let normally = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [task], existing: [])
        #expect(!normally.sessions.contains { $0.assessmentID == task.id })

        task.planFrom = date(day: 0, 12)
        let early = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [task], existing: [])
        #expect(early.sessions.contains { $0.assessmentID == task.id })
    }

    // MARK: Suggestions

    @Test func suggestionsComeFromWhatFolioKnows() {
        let physics = subjects[2]
        var exam = Assessment(title: "Trial exam", subjectID: physics.id, kind: .exam, due: date(day: 10, 9))
        exam.milestones = [Assessment.Milestone(title: "Finish summary notes", date: date(day: 4, 17))]
        let session = StudySession(subjectID: physics.id, start: date(day: 1, 16), end: date(day: 1, 17), assessmentID: exam.id, title: "Trial exam")
        let previous = StudySession(subjectID: physics.id, start: date(day: -2, 16), end: date(day: -2, 17), assessmentID: exam.id, outcome: .partly, note: "Got to question 5")
        let todos = [
            Todo(subjectID: physics.id, title: "Ask about question 7", createdAt: date(day: -3, 9)),
            Todo(subjectID: physics.id, title: "Redo motion questions", assessmentID: exam.id, createdAt: date(day: -1, 9)),
            Todo(subjectID: subjects[0].id, title: "Not physics"),
        ]
        let steps = PlanSuggestions.suggestions(
            for: session, assessment: exam, previous: previous, todos: todos, dueCards: 12,
            paper: PlanSuggestions.Paper(title: "2023 HSC · Paper 1", fileName: "2023-hsc-physics.pdf"), now: date(day: 0, 9)
        )

        #expect(steps.map(\.kind) == [.pickUp, .milestone, .todo, .todo, .cards, .paper])
        #expect(steps.map(\.title) == [
            "Pick up from last time: Got to question 5",
            "Finish summary notes for Trial exam",
            "Redo motion questions",
            "Ask about question 7",
            "Review 12 cards",
            "Practise a past paper: 2023 HSC · Paper 1",
        ])
        #expect(steps[5].reference == "2023-hsc-physics.pdf")
    }

    @Test func papersAreForExamsAndPlannedStepsArentSuggestedAgain() {
        let english = subjects[0]
        let essay = Assessment(title: "Essay", subjectID: english.id, due: date(day: 9, 9))
        let todo = Todo(subjectID: english.id, title: "Find three quotes")
        var session = StudySession(subjectID: english.id, start: date(day: 1, 16), end: date(day: 1, 17), assessmentID: essay.id)
        session.plan = [todo.step]
        let steps = PlanSuggestions.suggestions(
            for: session, assessment: essay, previous: nil, todos: [todo], dueCards: 0,
            paper: PlanSuggestions.Paper(title: "2022 HSC", fileName: "2022.pdf"), now: date(day: 0, 9)
        )
        #expect(steps.isEmpty)
    }

    @Test func aLongNoteIsShortened() {
        let session = StudySession(subjectID: subjects[0].id, start: date(day: 1, 16), end: date(day: 1, 17))
        let previous = StudySession(subjectID: subjects[0].id, start: date(day: 0, 16), end: date(day: 0, 17), note: String(repeating: "word ", count: 40))
        let step = PlanSuggestions.suggestions(for: session, assessment: nil, previous: previous, todos: [], dueCards: 0, paper: nil, now: date(day: 0, 18)).first
        #expect(step?.kind == .pickUp)
        #expect(step?.title.hasSuffix("…") == true)
        #expect((step?.title.count ?? 0) < 130)
    }

    // MARK: Carrying steps on

    @Test func unfinishedStepsGoToTheNextSessionForTheSameWork() {
        let english = subjects[0]
        let essayID = UUID()
        var finished = StudySession(subjectID: english.id, start: date(day: 0, 16), end: date(day: 0, 17), assessmentID: essayID, outcome: .partly)
        finished.plan = [
            PlanStep(title: "Plan paragraph 2", isDone: true),
            PlanStep(title: "Write paragraph 2"),
            PlanStep(title: "Review 4 cards", kind: .cards),
            PlanStep(title: "Pick up from last time: the intro", kind: .pickUp),
        ]
        let general = StudySession(subjectID: english.id, start: date(day: 1, 16), end: date(day: 1, 17))
        let essay = StudySession(subjectID: english.id, start: date(day: 2, 16), end: date(day: 2, 17), assessmentID: essayID)
        var sessions = [finished, general, essay]

        #expect(sessions.carrySteps(of: finished, now: date(day: 0, 17)).isEmpty)
        #expect(sessions[2].plan.map(\.title) == ["Write paragraph 2"])
        #expect(sessions[1].plan.isEmpty)
    }

    @Test func stepsWithNowhereToGoComeBack() {
        var finished = StudySession(subjectID: subjects[0].id, start: date(day: 0, 16), end: date(day: 0, 17))
        finished.plan = [PlanStep(title: "Write paragraph 2")]
        var sessions = [finished, StudySession(subjectID: subjects[1].id, start: date(day: 1, 16), end: date(day: 1, 17))]
        #expect(sessions.carrySteps(of: finished, now: date(day: 0, 17)).map(\.title) == ["Write paragraph 2"])
    }
}
