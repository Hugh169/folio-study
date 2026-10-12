import FolioKit
import SwiftUI

extension AppModel {
    /// Turns the timetable calendars' events, and the school timetable if
    /// there is one, into classes for the class-time signal.
    func refreshClasses() {
        var classes = TimetableReader.classes(from: timetableEvents, subjects: subjects)
        if let timetable = profile.timetable,
           let start = calendar.date(byAdding: .weekOfYear, value: -8, to: .now),
           let end = calendar.date(byAdding: .weekOfYear, value: 8, to: .now) {
            classes += timetable.classes(in: DateInterval(start: start, end: end), subjects: subjects, calendar: calendar)
        }
        live?.librarian?.update(classes: classes)
    }

    /// "Week A" or "Week B" for the school week a date is in, when the
    /// timetable runs over a fortnight.
    func weekName(for date: Date) -> String? {
        guard let timetable = profile.timetable, timetable.weekCount > 1 else { return nil }
        return Self.weekName(timetable.week(of: date, calendar: calendar))
    }

    static func weekName(_ week: Int) -> String {
        week == 0 ? String(localized: "Week A") : String(localized: "Week B")
    }

    /// The school timetable's classes on a day, earliest first.
    func timetableClasses(on day: Date) -> [ClassSession] {
        guard let timetable = profile.timetable, let whole = calendar.dateInterval(of: .day, for: day) else { return [] }
        return timetable.classes(in: whole, subjects: subjects, calendar: calendar)
    }

    /// Every class on a day, from the school timetable and the timetable
    /// calendars, earliest first.
    func classes(on day: Date) -> [ClassSession] {
        let fromCalendars = TimetableReader.classes(
            from: timetableEvents.filter { calendar.isDate($0.start, inSameDayAs: day) },
            subjects: subjects
        )
        return (timetableClasses(on: day) + fromCalendars).sorted { $0.start < $1.start }
    }

    /// A subject's next class in the coming three weeks.
    func nextClass(of subjectID: Subject.ID, after now: Date = .now) -> ClassSession? {
        for offset in 0..<21 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { break }
            if let lesson = classes(on: day).first(where: { $0.subjectID == subjectID && $0.end > now }) {
                return lesson
            }
        }
        return nil
    }

    /// When school runs on a day, in minutes after midnight: from the
    /// timetable when there is one, so not in the holidays, or else from
    /// school hours.
    func schoolHours(on day: Date) -> (start: Int, end: Int)? {
        if let timetable = profile.timetable {
            guard let whole = calendar.dateInterval(of: .day, for: day),
                  let span = timetable.schoolDays(in: whole, calendar: calendar).first
            else { return nil }
            return (minutes(span.start), minutes(span.end))
        }
        guard let school, school.weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        return (school.start, school.end)
    }

    /// A new timetable for the editor: school hours' bell times, with this
    /// school week as Week A.
    func newTimetable() -> SchoolTimetable {
        SchoolTimetable.suggested(
            within: profile.studyPreferences.schoolHours ?? pack?.schoolHours ?? SchoolHours(),
            weekAStart: SchoolTimetable.monday(of: Self.schoolWeek(around: .now, calendar: calendar), calendar: calendar)
        )
    }

    /// A day in the school week the student means by "this week": the
    /// current one, or the coming one at the weekend.
    static func schoolWeek(around date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let toMonday = weekday == 7 ? 2 : weekday == 1 ? 1 : 0
        return calendar.date(byAdding: .day, value: toMonday, to: calendar.startOfDay(for: date)) ?? date
    }

    private func minutes(_ date: Date) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

extension SchoolTimetable {
    /// Such as "Week A and Week B · 6 periods · 4 terms".
    var summary: String {
        var parts = [weekCount == 2 ? String(localized: "Week A and Week B") : String(localized: "Every week")]
        parts.append(String(localized: "\(periods.count) periods"))
        if !terms.isEmpty {
            parts.append(String(localized: "\(terms.count) terms"))
        }
        return parts.joined(separator: " · ")
    }
}
