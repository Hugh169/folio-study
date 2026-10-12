import Foundation
import Testing
@testable import FolioKit

struct TimetableTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }()
    let subjects = Profile.starter().subjects
    var maths: Subject { subjects[0] }
    var physics: Subject { subjects[2] }

    /// A time in October 2026, or September with `month: 9`. Clocks in Sydney
    /// go forward on Sunday 4 October.
    func time(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func whole(_ day: Date) -> DateInterval {
        calendar.dateInterval(of: .day, for: day)!
    }

    /// Week A has Maths first thing on Monday; Week B has Physics. Monday 5
    /// October starts a Week A.
    func fortnight() -> SchoolTimetable {
        var timetable = SchoolTimetable.suggested(within: SchoolHours(start: 9 * 60, end: 15 * 60 + 30), weekAStart: time(5))
        timetable.weekCount = 2
        let first = timetable.periods[0].id
        timetable.setSubject(maths.id, week: 0, weekday: 2, period: first)
        timetable.setSubject(physics.id, week: 1, weekday: 2, period: first)
        return timetable
    }

    @Test func suggestedPeriodsFillTheSchoolDay() {
        let periods = SchoolTimetable.suggested(within: SchoolHours(start: 8 * 60 + 45, end: 15 * 60 + 15), weekAStart: time(5)).periods
        #expect(periods.count == 6)
        #expect(periods.first?.start == 8 * 60 + 45)
        #expect(periods.allSatisfy { $0.end > $0.start })
        #expect((periods.last?.end ?? .max) <= 15 * 60 + 15)
        // Recess after period 2 and lunch after period 4.
        #expect(periods[2].start - periods[1].end == 20)
        #expect(periods[4].start - periods[3].end == 40)
    }

    @Test func weeksAlternateBothWaysFromWeekA() {
        let timetable = fortnight()
        #expect(timetable.week(of: time(5), calendar: calendar) == 0)
        #expect(timetable.week(of: time(9, 14), calendar: calendar) == 0)
        #expect(timetable.week(of: time(11, 20), calendar: calendar) == 0, "Sunday ends the week")
        #expect(timetable.week(of: time(12), calendar: calendar) == 1)
        #expect(timetable.week(of: time(19), calendar: calendar) == 0)
        #expect(timetable.week(of: time(28, month: 9), calendar: calendar) == 1)
        #expect(timetable.week(of: time(21, month: 9), calendar: calendar) == 0)

        var weekly = timetable
        weekly.weekCount = 1
        #expect(weekly.week(of: time(12), calendar: calendar) == 0)
    }

    @Test func classesFollowTheWeek() {
        let timetable = fortnight()
        #expect(timetable.classes(in: whole(time(5)), subjects: subjects, calendar: calendar).map(\.subjectID) == [maths.id])
        #expect(timetable.classes(in: whole(time(12)), subjects: subjects, calendar: calendar).map(\.subjectID) == [physics.id])
        #expect(timetable.classes(in: whole(time(28, month: 9)), subjects: subjects, calendar: calendar).map(\.subjectID) == [physics.id])
        #expect(timetable.classes(in: whole(time(6)), subjects: subjects, calendar: calendar).isEmpty)
        #expect(timetable.classes(in: whole(time(5)), subjects: subjects, calendar: calendar).first?.title == "Mathematics, Period 1")
    }

    @Test func bellTimesStayPutWhenTheClocksChange() {
        let timetable = fortnight()
        let before = timetable.classes(in: whole(time(28, month: 9)), subjects: subjects, calendar: calendar)
        let after = timetable.classes(in: whole(time(5)), subjects: subjects, calendar: calendar)
        for lesson in before + after {
            #expect(calendar.component(.hour, from: lesson.start) == 9)
            #expect(calendar.component(.minute, from: lesson.start) == 0)
        }
        #expect(before.count == 1 && after.count == 1)
    }

    @Test func holidaysHaveNoClasses() {
        var timetable = fortnight()
        // Term 4 starts on Monday 12 October.
        timetable.terms = [SchoolTimetable.Term(start: time(12), end: time(18, month: 12))]
        #expect(timetable.classes(in: whole(time(5)), subjects: subjects, calendar: calendar).isEmpty)
        #expect(timetable.schoolDays(in: whole(time(5)), calendar: calendar).isEmpty)
        #expect(timetable.classes(in: whole(time(12)), subjects: subjects, calendar: calendar).count == 1)
        #expect(timetable.isInTerm(time(18, 15, month: 12), calendar: calendar), "The last day counts")
        #expect(!timetable.isInTerm(time(19, month: 12), calendar: calendar))
    }

    @Test func aSchoolDayRunsFromTheFirstBellToTheLast() throws {
        let timetable = fortnight()
        let day = try #require(timetable.schoolDays(in: whole(time(5)), calendar: calendar).first)
        #expect(day.start == time(5, 9))
        #expect(day.end == calendar.date(bySettingHour: timetable.periods.last!.end / 60, minute: timetable.periods.last!.end % 60, second: 0, of: time(5)))
        // Tuesday has no classes yet, so it isn't kept free.
        #expect(timetable.schoolDays(in: whole(time(6)), calendar: calendar).isEmpty)
    }

    @Test func choosingWhichWeekThisIs() {
        var timetable = fortnight()
        // The student says the week of Wednesday 7 October is Week B.
        timetable.setWeek(1, for: time(7, 12), calendar: calendar)
        #expect(timetable.week(of: time(7), calendar: calendar) == 1)
        #expect(timetable.week(of: time(14), calendar: calendar) == 0)
        #expect(calendar.component(.weekday, from: timetable.weekAStart) == 2)
    }

    @Test func editingLessons() {
        var timetable = fortnight()
        let first = timetable.periods[0].id
        let second = timetable.periods[1].id
        timetable.setSubject(physics.id, week: 0, weekday: 3, period: second)
        #expect(timetable.subject(week: 0, weekday: 3, period: second) == physics.id)
        timetable.setSubject(nil, week: 0, weekday: 3, period: second)
        #expect(timetable.subject(week: 0, weekday: 3, period: second) == nil)

        timetable.copyWeekAToB()
        #expect(timetable.subject(week: 1, weekday: 2, period: first) == maths.id)

        // A removed subject and Week B's classes go once there's one week.
        timetable.weekCount = 1
        let tidied = timetable.tidied(keeping: [physics.id])
        #expect(tidied.lessons.isEmpty)
    }

    @Test func aFileThatArrivesInClassPointsToThatSubject() async {
        let timetable = fortnight()
        var profile = Profile.starter()
        profile.subjects = subjects
        let voter = TimetableVoter(classes: timetable.classes(in: DateInterval(start: time(1), end: time(31)), subjects: subjects, calendar: calendar))
        let worksheet = Evidence(fileName: "worksheet.pdf", contentType: "com.adobe.pdf", text: "Questions 1 to 10", arrived: time(12, 9, 20))
        let vote = await voter.vote(on: worksheet, profile: profile)
        #expect(vote.top?.id == physics.id)
        #expect(vote.reasons == ["Arrived during Physics, Period 1"])
    }

    @Test func plannerKeepsSchoolDaysFreeButNotTheHolidays() {
        var timetable = fortnight()
        timetable.terms = [SchoolTimetable.Term(start: time(12), end: time(18, month: 12))]
        var preferences = StudyPreferences()
        preferences.weekdayWindows = [StudyPreferences.Window(start: 9 * 60, end: 12 * 60)]
        let planner = WeekPlanner(calendar: calendar, preferences: preferences, timetable: timetable)
        let mondayMorning = { (week: Date) in
            planner.plan(weekStart: week, now: week, subjects: subjects, assessments: [], existing: [])
                .sessions.filter { calendar.isDate($0.start, inSameDayAs: week) }
        }
        // In the holidays Monday is free; in term it's a school day.
        #expect(!mondayMorning(time(5)).isEmpty)
        #expect(mondayMorning(time(12)).isEmpty)
    }

    @Test func savedTimetablesLoad() throws {
        var profile = Profile.starter()
        profile.timetable = fortnight()
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(Profile.self, from: data).timetable == profile.timetable)

        let minimal = #"{"weekAStart": 0}"#
        let timetable = try JSONDecoder().decode(SchoolTimetable.self, from: Data(minimal.utf8))
        #expect(timetable.weekCount == 1)
        #expect(timetable.lessons.isEmpty && timetable.terms.isEmpty)
    }
}
