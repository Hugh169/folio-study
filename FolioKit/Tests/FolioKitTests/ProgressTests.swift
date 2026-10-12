import Foundation
import Testing
@testable import FolioKit

/// Marks, study time, the weekly review, busy weeks ahead and term summaries.
struct ProgressTests {
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

    func date(day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: monday)!
    }

    func marked(_ title: String, _ score: Double, of outOf: Double, weighting: Double?, day: Int, subject: Int = 0) -> Assessment {
        Assessment(title: title, subjectID: subjects[subject].id, due: date(day: day), weighting: weighting, status: .marked, mark: Assessment.Mark(score: score, outOf: outOf))
    }

    // MARK: Standing

    @Test func marksAreAveragedByWhatEachIsWorth() throws {
        let standing = Standing(assessments: [
            marked("Exam", 40, of: 50, weighting: 30, day: -10),
            marked("Essay", 18, of: 25, weighting: 20, day: -30),
            Assessment(title: "Not back yet", subjectID: subjects[0].id, due: date(day: -2), weighting: 25, status: .submitted),
        ])
        #expect(abs(try #require(standing.average) - 0.768) < 0.0001)
        #expect(standing.weightMarked == 50)
        #expect(standing.points.map(\.title) == ["Essay", "Exam"])
    }

    @Test func aMarkWithoutAWeightingCountsAsAUsualOne() throws {
        let standing = Standing(assessments: [
            marked("Test", 10, of: 20, weighting: 20, day: -10),
            marked("Quiz", 10, of: 10, weighting: nil, day: -5),
        ])
        #expect(abs(try #require(standing.average) - 0.75) < 0.0001)
        #expect(standing.weightMarked == 20)
    }

    @Test func withNoWeightingsMarksCountTheSame() throws {
        let standing = Standing(assessments: [marked("A", 6, of: 10, weighting: nil, day: -3), marked("B", 9, of: 10, weighting: nil, day: -1)])
        #expect(abs(try #require(standing.average) - 0.75) < 0.0001)
        #expect(standing.weightMarked == nil)
    }

    @Test func gradesAreListedButNotAveraged() {
        var band = Assessment(title: "Speech", subjectID: subjects[0].id, due: date(day: -4), weighting: 15, status: .marked)
        band.mark = Assessment.Mark(grade: "Band 5")
        let standing = Standing(assessments: [band])
        #expect(standing.average == nil)
        #expect(standing.grades.map(\.grade) == ["Band 5"])
        #expect(standing.weightMarked == 15)
        #expect(!standing.isEmpty)
        #expect(Standing(assessments: []).isEmpty)
    }

    // MARK: Study time

    @Test func studyTimeIsComparedWithThePlanAndWithWhatsDue() throws {
        let (english, maths, physics) = (subjects[0], subjects[1], subjects[2])
        let sessions = [
            StudySession(subjectID: english.id, start: date(day: 0, 16), end: date(day: 0, 17), doneMinutes: 60, outcome: .done),
            StudySession(subjectID: english.id, start: date(day: 1, 16), end: date(day: 1, 17), doneMinutes: 45, outcome: .partly),
            StudySession(subjectID: maths.id, start: date(day: 2, 16), end: date(day: 2, 17), doneMinutes: 0, outcome: .skipped),
            StudySession(subjectID: maths.id, start: date(day: 3, 16), end: date(day: 3, 17), doneMinutes: 30, outcome: .partly),
            StudySession(subjectID: physics.id, start: date(day: 4, 16), end: date(day: 4, 17, 30)),
        ]
        let due = [
            Assessment(title: "Essay", subjectID: english.id, due: date(day: 10), estimateHours: 4),
            Assessment(title: "Exam", subjectID: physics.id, kind: .exam, due: date(day: 12), estimateHours: 6),
        ]
        let times = StudyTime.compute(
            subjectIDs: [english.id, maths.id, physics.id], sessions: sessions, assessments: due,
            period: DateInterval(start: monday, end: date(day: 7, 0)), dueBy: date(day: 28), now: date(day: 5)
        )
        let englishTime = try #require(times.first { $0.subjectID == english.id })
        #expect(englishTime.studied == 105)
        #expect(englishTime.planned == 120)
        #expect(abs(englishTime.studyShare - 105.0 / 135) < 0.0001)
        #expect(abs(englishTime.dueShare - 0.4) < 0.0001)
        let mathsTime = try #require(times.first { $0.subjectID == maths.id })
        #expect(mathsTime.planned == 60)
        let physicsTime = try #require(times.first { $0.subjectID == physics.id })
        #expect(physicsTime.studied == 0)
        #expect(abs(physicsTime.dueShare - 0.6) < 0.0001)
        // Physics has most of what's due and none of the study.
        #expect(physicsTime.isBehind(totalStudied: 135))
        #expect(!englishTime.isBehind(totalStudied: 135))
        // Too little study to say.
        #expect(!physicsTime.isBehind(totalStudied: 60))
    }

    // MARK: Weekly review

    @Test func theWeekIsReviewedHonestly() {
        let (english, maths) = (subjects[0], subjects[1])
        let sessions = [
            StudySession(subjectID: english.id, start: date(day: 0, 16), end: date(day: 0, 17), doneMinutes: 60, outcome: .done),
            StudySession(subjectID: english.id, start: date(day: 2, 16), end: date(day: 2, 17), doneMinutes: 30, outcome: .partly),
            StudySession(subjectID: maths.id, start: date(day: 3, 16), end: date(day: 3, 17), doneMinutes: 0, outcome: .skipped),
            StudySession(subjectID: maths.id, start: date(day: 5, 10), end: date(day: 5, 11, 30)),
            StudySession(subjectID: maths.id, start: date(day: 8, 16), end: date(day: 8, 17)),
        ]
        var essay = Assessment(title: "Essay", subjectID: english.id, due: date(day: 4), status: .submitted)
        essay.markedAt = nil
        let quiz = Assessment(title: "Quiz", subjectID: maths.id, due: date(day: 2), status: .notStarted)
        var oldTask = marked("Old task", 15, of: 20, weighting: 10, day: -20)
        oldTask.markedAt = date(day: 3, 12)
        let next = Assessment(title: "Speech", subjectID: english.id, due: date(day: 9))
        let todos = [
            Todo(subjectID: english.id, title: "Done this week", isDone: true, doneAt: date(day: 1, 18)),
            Todo(subjectID: english.id, title: "Done before", isDone: true, doneAt: date(day: -3)),
            Todo(subjectID: english.id, title: "Open"),
        ]
        let review = WeekReview(weekStart: monday, calendar: calendar, sessions: sessions, assessments: [essay, quiz, oldTask, next], todos: todos, now: date(day: 7, 10))

        #expect(review.studied == 90)
        #expect(review.planned == 210)
        #expect((review.done, review.partly, review.skipped, review.notRecorded) == (1, 1, 1, 1))
        #expect(review.bySubject.first?.subjectID == english.id)
        #expect(review.handedIn.map(\.title) == ["Essay"])
        #expect(review.overdue.map(\.title) == ["Quiz"])
        #expect(review.marksBack.map(\.title) == ["Old task"])
        #expect(review.todosDone == 1)
        #expect(review.dueNext.map(\.title) == ["Speech"])
        #expect(review.plannedNext == 60)
    }

    // MARK: Busy weeks

    var check: WorkloadCheck { WorkloadCheck(planner: WeekPlanner(calendar: calendar)) }

    @Test func aUsualWeekHasRoomForSixteenSessions() {
        // Two after school on weekdays, and three on each weekend day.
        #expect(check.room(inWeekStarting: date(day: 7, 0), now: date(day: 0)) == 16 * 60)
    }

    @Test func aWeekWithThreeThingsDueIsFlaggedWithEarlierStarts() throws {
        let now = date(day: 0, 9)
        let due = [
            Assessment(title: "Essay", subjectID: subjects[0].id, due: date(day: 22, 9), weighting: 20),
            Assessment(title: "Report", subjectID: subjects[2].id, kind: .practical, due: date(day: 23, 9), weighting: 15),
            Assessment(title: "Speech", subjectID: subjects[0].id, kind: .presentation, due: date(day: 24, 9), weighting: 10),
            Assessment(title: "Reading", subjectID: subjects[1].id, kind: .homework, due: date(day: 25, 9)),
        ]
        let warnings = check.warnings(assessments: due, sessions: [], now: now)
        let warning = try #require(warnings.first)
        #expect(warnings.count == 1)
        #expect(warning.week.start == date(day: 21, 0))
        #expect(warning.due.map(\.title) == ["Essay", "Report", "Speech", "Reading"])
        #expect(warning.isCrowded)
        // The report and speech start a week before they would. The essay's
        // work starts tomorrow anyway, so starting today wouldn't help.
        let starts = Dictionary(uniqueKeysWithValues: warning.startEarlier.map { ($0.title, $0.from) })
        #expect(starts["Essay"] == nil)
        #expect(starts["Report"] == calendar.date(byAdding: .day, value: -7, to: try #require(due[1].workStart(calendar: calendar))))
        #expect(starts["Speech"] == calendar.date(byAdding: .day, value: -7, to: try #require(due[2].workStart(calendar: calendar))))
    }

    @Test func tooMuchWorkIsFlaggedAndStartingEarlierEasesIt() throws {
        let now = date(day: 0, 9)
        var tasks = [36, 37, 38].map { day in
            Assessment(title: "Major work \(day)", subjectID: subjects[day % 3].id, due: date(day: day, 9), estimateHours: 20)
        }
        let warnings = check.warnings(assessments: tasks, sessions: [], now: now)
        // The work piles up in the weeks before they're due, and those weeks
        // and the one they're due in are one stretch.
        #expect(warnings.count == 1)
        let busy = try #require(warnings.first)
        #expect(busy.week.contains(date(day: 28, 12)) && busy.week.contains(date(day: 37, 12)))
        #expect(busy.isTooMuchWork)
        #expect(busy.isCrowded)
        #expect(Set(busy.startEarlier.map(\.title)) == Set(tasks.map(\.title)))

        let work = { (tasks: [Assessment]) in
            tasks.reduce(0) { total, task in
                total + check.planner.demands(for: task, weekStart: date(day: 28, 0), weekEnd: date(day: 35, 0), now: now, existing: []).reduce(0) { $0 + $1.minutes }
            }
        }
        let before = work(tasks)
        for index in tasks.indices {
            tasks[index].planFrom = busy.startEarlier.first { $0.assessmentID == tasks[index].id }?.from
        }
        #expect(work(tasks) < before)
    }

    @Test func nextWeekIsTooLateToWarnAbout() {
        let now = date(day: 0, 9)
        let due = (8...10).map { Assessment(title: "Task \($0)", subjectID: subjects[$0 % 3].id, due: date(day: $0, 9), weighting: 20) }
        #expect(check.warnings(assessments: due, sessions: [], now: now).isEmpty)
    }

    @Test func aQuietMonthHasNoWarnings() {
        let now = date(day: 0, 9)
        let due = [
            Assessment(title: "Essay", subjectID: subjects[0].id, due: date(day: 15, 9), weighting: 20),
            Assessment(title: "Quiz", subjectID: subjects[1].id, kind: .test, due: date(day: 30, 9), weighting: 5),
        ]
        #expect(check.warnings(assessments: due, sessions: [], now: now).isEmpty)
    }

    // MARK: Terms

    @Test func aTermIsSummedUpBySubject() throws {
        let (english, maths) = (subjects[0], subjects[1])
        let term = DateInterval(start: date(day: -30, 0), end: date(day: 30, 0))
        let sessions = [
            StudySession(subjectID: english.id, start: date(day: -3, 16), end: date(day: -3, 17), doneMinutes: 50, outcome: .done),
            StudySession(subjectID: english.id, start: date(day: -60, 16), end: date(day: -60, 17), doneMinutes: 60, outcome: .done),
            StudySession(subjectID: maths.id, start: date(day: -2, 16), end: date(day: -2, 17)),
        ]
        let assessments = [
            marked("Essay", 18, of: 20, weighting: 25, day: -5),
            marked("Last term's essay", 10, of: 20, weighting: 25, day: -50),
            Assessment(title: "Algebra test", subjectID: maths.id, kind: .test, due: date(day: 10), weighting: 10),
        ]
        let summary = TermSummary(
            subjectIDs: [english.id, maths.id], range: term, sessions: sessions, assessments: assessments,
            fileDates: [english.id: [date(day: -1), date(day: -40)], maths.id: [date(day: -2), date(day: -3)]]
        )
        let englishLine = try #require(summary.lines.first { $0.subjectID == english.id })
        #expect(englishLine.studied == 50)
        #expect(englishLine.handedIn == 1)
        #expect(englishLine.files == 1)
        #expect(abs(try #require(englishLine.standing.average) - 0.9) < 0.0001)
        let mathsLine = try #require(summary.lines.first { $0.subjectID == maths.id })
        #expect(mathsLine.studied == 0)
        #expect(mathsLine.files == 2)
        #expect(summary.studied == 50)
        #expect(summary.files == 3)
    }
}
