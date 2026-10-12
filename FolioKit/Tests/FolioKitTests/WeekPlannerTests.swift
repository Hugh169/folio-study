import Foundation
import Testing
@testable import FolioKit

struct WeekPlannerTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        calendar.firstWeekday = 2
        return calendar
    }()
    let subjects = Profile.starter().subjects

    /// Monday 5 October 2026, the week in the design mock-ups.
    var monday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
    }

    func date(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: monday)!
    }

    @Test func everySubjectGetsASessionInAnEmptyWeek() {
        let planner = WeekPlanner(calendar: calendar)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [], existing: [])

        #expect(Set(result.sessions.map(\.subjectID)) == Set(subjects.map(\.id)))
        #expect(result.added == result.sessions.count)
    }

    @Test func nothingIsPlannedDuringSchool() {
        let school = try! #require(StudyPreferences().schoolHours)
        let planner = WeekPlanner(calendar: calendar)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [], existing: [])

        for session in result.sessions {
            let weekday = calendar.component(.weekday, from: session.start)
            guard school.weekdays.contains(weekday) else { continue }
            let start = calendar.component(.hour, from: session.start) * 60 + calendar.component(.minute, from: session.start)
            let end = calendar.component(.hour, from: session.end) * 60 + calendar.component(.minute, from: session.end)
            #expect(end <= school.start || start >= school.end)
        }
    }

    @Test func assessmentWorkHappensBeforeTheDueDate() {
        let planner = WeekPlanner(calendar: calendar)
        let physics = subjects[2]
        let due = date(day: 3, 9)
        let report = Assessment(title: "Practical report", subjectID: physics.id, due: due, weighting: 20)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [report], existing: [])

        let work = result.sessions.filter { $0.assessmentID == report.id }
        #expect(work.count >= 2)
        #expect(work.allSatisfy { $0.subjectID == physics.id && $0.title == "Practical report" })
        // Nothing on the day it's due.
        #expect(work.allSatisfy { $0.end <= calendar.startOfDay(for: due) })
    }

    @Test func workRampsUpAsTheDueDateGetsCloser() {
        let planner = WeekPlanner(calendar: calendar)
        let task = Assessment(title: "Depth Study", subjectID: subjects[0].id, due: date(day: 21, 9), weighting: 30)
        let now = date(day: 0, 7)
        let first = planner.demands(for: task, weekStart: monday, weekEnd: date(day: 7, 0), now: now, existing: [])
        let last = planner.demands(for: task, weekStart: date(day: 14, 0), weekEnd: date(day: 21, 0), now: now, existing: [])

        let minutes = { (demands: [WeekPlanner.Demand]) in demands.reduce(0) { $0 + $1.minutes } }
        #expect(minutes(first) > 0)
        #expect(minutes(last) > minutes(first))
        // Three weeks of shares add up to about the estimate.
        let middle = planner.demands(for: task, weekStart: date(day: 7, 0), weekEnd: date(day: 14, 0), now: now, existing: [])
        let total = Double(minutes(first) + minutes(middle) + minutes(last)) / 60
        #expect(abs(total - task.plannedHours) <= 2)
    }

    @Test func hoursAlreadyStudiedCountTowardsTheEstimate() {
        let planner = WeekPlanner(calendar: calendar)
        let task = Assessment(title: "Essay", subjectID: subjects[1].id, due: date(day: 4, 9), estimateHours: 3)
        let done = StudySession(subjectID: subjects[1].id, start: date(day: -1, 16), end: date(day: -1, 17), assessmentID: task.id, doneMinutes: 180)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [task], existing: [done])

        #expect(!result.sessions.contains { $0.assessmentID == task.id && $0.id != done.id })
    }

    @Test func examsGetRevisionAndNothingIsPlannedDuringThem() {
        let planner = WeekPlanner(calendar: calendar)
        let maths = subjects[0]
        let exam = Assessment(title: "Trial exam", subjectID: maths.id, kind: .exam, due: date(day: 5, 13), lengthMinutes: 120, weighting: 30)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [exam], existing: [])

        let revision = result.sessions.filter { $0.assessmentID == exam.id }
        #expect(!revision.isEmpty)
        #expect(revision.allSatisfy { $0.end <= calendar.startOfDay(for: exam.due) })
        let sitting = try! #require(exam.sitting)
        #expect(!result.sessions.contains { DateInterval(start: $0.start, end: $0.end).intersects(sitting) && $0.end != sitting.start && $0.start != sitting.end })
    }

    @Test func sessionsAreNamedForTheNextMilestone() {
        let planner = WeekPlanner(calendar: calendar)
        var task = Assessment(title: "Depth Study", subjectID: subjects[3].id, due: date(day: 6, 9), estimateHours: 2)
        task.milestones = [Assessment.Milestone(title: "Draft", date: date(day: 5, 17))]
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [task], existing: [])

        let titles = result.sessions.filter { $0.assessmentID == task.id }.map(\.title)
        #expect(!titles.isEmpty)
        #expect(titles.allSatisfy { $0 == "Depth Study: Draft" })
    }

    @Test func defaultEstimatesFollowKindAndWeighting() {
        #expect(Assessment(title: "", subjectID: UUID(), due: .now, weighting: 25).defaultEstimateHours == 10)
        #expect(Assessment(title: "", subjectID: UUID(), kind: .test, due: .now).defaultEstimateHours == 2)
        #expect(Assessment(title: "", subjectID: UUID(), kind: .exam, due: .now).defaultEstimateHours == 10)
    }

    @Test func sessionsGoAroundEventsWithABuffer() {
        // A Monday afternoon dentist appointment, 4:30 to 5:30.
        let appointment = DateInterval(start: date(day: 0, 16, 30), end: date(day: 0, 17, 30))
        let planner = WeekPlanner(calendar: calendar)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [], existing: [], busy: [appointment])

        let blocked = DateInterval(start: date(day: 0, 16, 15), end: date(day: 0, 17, 45))
        #expect(result.sessions.allSatisfy { !DateInterval(start: $0.start, end: $0.end).intersects(blocked) || $0.end == blocked.start || $0.start == blocked.end })
        #expect(Set(result.sessions.map(\.subjectID)) == Set(subjects.map(\.id)))
    }

    @Test func universityDaysFitAroundClasses() {
        var preferences = StudyPreferences.university
        preferences.maxSessionsPerDay = 2
        // A full Tuesday: lectures 9–11 and 1–3, a lab 3–6.
        let classes = [
            DateInterval(start: date(day: 1, 9), end: date(day: 1, 11)),
            DateInterval(start: date(day: 1, 13), end: date(day: 1, 15)),
            DateInterval(start: date(day: 1, 15), end: date(day: 1, 18)),
        ]
        let planner = WeekPlanner(calendar: calendar, preferences: preferences)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: subjects, assessments: [], existing: [], busy: classes)

        for session in result.sessions {
            let span = DateInterval(start: session.start, end: session.end)
            #expect(!classes.contains { $0.intersects(span) && $0.end != span.start && $0.start != span.end })
        }
        // With no school hours, a weekday morning can be used.
        #expect(result.sessions.contains { calendar.component(.hour, from: $0.start) < 12 && calendar.component(.weekday, from: $0.start) != 1 && calendar.component(.weekday, from: $0.start) != 7 })
    }

    @Test func finishedAssessmentsDontGetSessions() {
        let planner = WeekPlanner(calendar: calendar)
        let physics = subjects[2]
        let done = Assessment(title: "Practical report", subjectID: physics.id, due: date(day: 3, 9), status: .submitted)
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: [physics], assessments: [done], existing: [])

        #expect(result.sessions.count == 1)
        #expect(result.sessions.first.map { $0.end.timeIntervalSince($0.start) } == 3600)
    }

    @Test func homeworkGetsOneSessionInTheDaysBefore() {
        let planner = WeekPlanner(calendar: calendar)
        let chemistry = subjects[3]
        let homework = Assessment(title: "Questions 1–10", subjectID: chemistry.id, kind: .homework, due: date(day: 4, 9))
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: [], assessments: [homework], existing: [])

        let work = result.sessions.filter { $0.assessmentID == homework.id }
        #expect(homework.plannedHours == 1)
        #expect(work.count == 1)
        // In the three days before, not on the day it's due.
        #expect(work.allSatisfy { $0.start >= date(day: 1, 0) && $0.end <= date(day: 4, 0) })
    }

    @Test func recordedSessionsSurviveReplanning() {
        let planner = WeekPlanner(calendar: calendar)
        let physics = subjects[2]
        // Started early with the timer: it's later this week, but already done.
        let early = StudySession(subjectID: physics.id, start: date(day: 3, 16), end: date(day: 3, 17), doneMinutes: 50, outcome: .done)
        let untouched = StudySession(subjectID: physics.id, start: date(day: 4, 16), end: date(day: 4, 17))
        let result = planner.plan(weekStart: monday, now: date(day: 0, 7), subjects: [], assessments: [], existing: [early, untouched])
        #expect(result.sessions.contains(early))
        #expect(!result.sessions.contains(untouched))
    }

    @Test func subtractingBusyTimeSplitsWindows() {
        let window = DateInterval(start: date(day: 0, 9), end: date(day: 0, 17))
        let lunch = DateInterval(start: date(day: 0, 12), end: date(day: 0, 13))
        let free = WeekPlanner.subtract([lunch], from: [window])
        #expect(free == [DateInterval(start: date(day: 0, 9), end: date(day: 0, 12)), DateInterval(start: date(day: 0, 13), end: date(day: 0, 17))])
    }

    @Test func sessionsThatAlreadyStartedAreKept() {
        let planner = WeekPlanner(calendar: calendar)
        let past = StudySession(subjectID: subjects[0].id, start: date(day: 0, 16), end: date(day: 0, 17))
        let future = StudySession(subjectID: subjects[1].id, start: date(day: 5, 9), end: date(day: 5, 10))
        let result = planner.plan(weekStart: monday, now: date(day: 2, 12), subjects: subjects, assessments: [], existing: [past, future])

        #expect(result.sessions.contains(past))
        #expect(!result.sessions.contains(future))
        #expect(result.sessions.allSatisfy { $0 == past || $0.start >= date(day: 2, 12) })
    }
}
