import Foundation
import Testing
@testable import FolioKit

struct DueDateFinderTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        calendar.locale = Locale(identifier: "en_AU")
        return calendar
    }()

    /// Friday 9 October 2026, 10 am.
    var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 10))!
    }

    func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    @Test func findsADueDateWithATime() throws {
        let sheet = "Assessment Task 2: Depth Study\nDue date: Friday 23 October 2026 at 5:00 pm\nWeighting: 30%"
        let found = try #require(DueDateFinder.dueDate(in: sheet, now: now, calendar: calendar))
        let date = parts(found.date)
        #expect(date.day == 23 && date.month == 10 && date.hour == 17)
        #expect(found.context.hasPrefix("Due:"))
    }

    @Test func aDateWithoutATimeMeansNineInTheMorning() throws {
        let sheet = "Please submit your essay by 2 November 2026 through the portal."
        let found = try #require(DueDateFinder.dueDate(in: sheet, now: now, calendar: calendar))
        #expect(parts(found.date).hour == 9)
        #expect(parts(found.date).day == 2)
    }

    @Test func historicalDatesAreIgnored() {
        let notes = "The Treaty of Versailles was signed on 28 June 1919. Germany lost its colonies."
        #expect(DueDateFinder.dueDate(in: notes, now: now, calendar: calendar) == nil)
    }

    @Test func datesWithoutADueWordAreIgnored() {
        let notice = "The excursion to the museum is on 30 October 2026. Bring a packed lunch."
        #expect(DueDateFinder.dueDate(in: notice, now: now, calendar: calendar) == nil)
    }

    @Test func aDateInAPastMonthMeansNextYear() throws {
        let sheet = "Major project — due 14 March"
        let found = try #require(DueDateFinder.dueDate(in: sheet, now: now, calendar: calendar))
        #expect(parts(found.date).year == 2027)
    }
}

struct TimetableReaderTests {
    @Test func readsCourseCodesFromDifferentUniversities() {
        let titles = [
            "COMP1511 Lecture",
            "COMP1511 Tutorial T13A",
            "MATH1131 - Mathematics 1A - Lecture",
            "MATH 1131 Tut",
            "INFO1110 Introduction to Programming (Lecture)",
            "FIT1045 Workshop 1",
            "Lecture: ECON1101 Microeconomics 1",
            "BIOL1001 LAB 03",
            "Coffee with Sam",
        ]
        let courses = TimetableReader.courses(in: titles)
        let byCode = Dictionary(uniqueKeysWithValues: courses.map { ($0.code, $0) })

        #expect(Set(byCode.keys) == ["COMP1511", "MATH1131", "INFO1110", "FIT1045", "ECON1101", "BIOL1001"])
        #expect(byCode["MATH1131"]?.name == "Mathematics 1A")
        #expect(byCode["INFO1110"]?.name == "Introduction to Programming")
        #expect(byCode["ECON1101"]?.name == "Microeconomics 1")
        #expect(byCode["COMP1511"]?.name == nil)
        #expect(byCode["COMP1511"]?.classCount == 2)
        #expect(courses.first?.code == "COMP1511")
    }

    @Test func plainEventsHaveNoCourse() {
        #expect(TimetableReader.code(in: "Netball training") == nil)
        #expect(TimetableReader.code(in: "Year 12 assembly") == nil)
        #expect(TimetableReader.code(in: "Room 2024 booking") == nil)
    }
}
