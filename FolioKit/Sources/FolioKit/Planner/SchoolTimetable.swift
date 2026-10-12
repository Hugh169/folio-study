import Foundation

/// A school's repeating timetable, for students whose classes aren't in a
/// calendar: one week, or a fortnight of Week A and Week B. Its classes tell
/// Folio which lesson a file arrived in, and the planner keeps school days
/// free, except in the holidays when term dates are given.
public struct SchoolTimetable: Hashable, Codable, Sendable {
    /// A period in the school day. Bell times are the same every day.
    public struct Period: Hashable, Codable, Sendable, Identifiable {
        public var id: UUID
        /// Such as "Period 1".
        public var name: String
        /// Minutes after midnight.
        public var start: Int
        public var end: Int

        public init(id: UUID = UUID(), name: String, start: Int, end: Int) {
            self.id = id
            self.name = name
            self.start = start
            self.end = end
        }
    }

    /// One class: a subject in a period, on a day of Week A or Week B.
    public struct Lesson: Hashable, Codable, Sendable {
        /// 0 for Week A, 1 for Week B.
        public var week: Int
        /// The `Calendar` weekday, such as 2 for Monday.
        public var weekday: Int
        public var periodID: Period.ID
        public var subjectID: Subject.ID

        public init(week: Int, weekday: Int, periodID: Period.ID, subjectID: Subject.ID) {
            self.week = week
            self.weekday = weekday
            self.periodID = periodID
            self.subjectID = subjectID
        }
    }

    /// A term, from its first day to its last. Days outside every term are holidays.
    public struct Term: Hashable, Codable, Sendable, Identifiable {
        public var id: UUID
        public var start: Date
        public var end: Date

        public init(id: UUID = UUID(), start: Date, end: Date) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// 1, or 2 for Week A and Week B.
    public var weekCount: Int
    /// A Monday in Week A. Weeks alternate from it, forwards and back.
    public var weekAStart: Date
    public var periods: [Period]
    public var lessons: [Lesson]
    /// With no terms, every week has classes.
    public var terms: [Term]

    public init(weekCount: Int = 1, weekAStart: Date, periods: [Period] = [], lessons: [Lesson] = [], terms: [Term] = []) {
        self.weekCount = weekCount
        self.weekAStart = weekAStart
        self.periods = periods
        self.lessons = lessons
        self.terms = terms
    }

    // Missing fields fall back to defaults, so older settings files still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekCount = min(max(try container.decodeIfPresent(Int.self, forKey: .weekCount) ?? 1, 1), 2)
        weekAStart = try container.decode(Date.self, forKey: .weekAStart)
        periods = try container.decodeIfPresent([Period].self, forKey: .periods) ?? []
        lessons = try container.decodeIfPresent([Lesson].self, forKey: .lessons) ?? []
        terms = try container.decodeIfPresent([Term].self, forKey: .terms) ?? []
    }

    /// A new timetable with six periods filling the school day, a 20-minute
    /// recess after the second and a 40-minute lunch after the fourth.
    public static func suggested(within hours: SchoolHours, weekAStart: Date) -> SchoolTimetable {
        let breaks = [2: 20, 4: 40]
        let teaching = hours.end - hours.start - breaks.values.reduce(0, +)
        let length = max(30, teaching / 6 / 5 * 5)
        var start = hours.start
        var periods: [Period] = []
        for number in 1...6 {
            periods.append(Period(name: String(localized: "Period \(number)", bundle: .module), start: start, end: start + length))
            start += length + (breaks[number] ?? 0)
        }
        return SchoolTimetable(weekAStart: weekAStart, periods: periods)
    }

    // MARK: Weeks

    /// The Monday that starts the school week a date is in. Sunday counts as
    /// the end of the week before.
    public static func monday(of date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let sinceMonday = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -sinceMonday, to: day) ?? day
    }

    /// 0 for Week A and 1 for Week B. Always 0 when every week is the same.
    public func week(of date: Date, calendar: Calendar) -> Int {
        guard weekCount > 1 else { return 0 }
        let anchor = Self.monday(of: weekAStart, calendar: calendar)
        let days = calendar.dateComponents([.day], from: anchor, to: Self.monday(of: date, calendar: calendar)).day ?? 0
        let weeks = Int((Double(days) / 7).rounded(.down))
        return ((weeks % weekCount) + weekCount) % weekCount
    }

    /// Makes the week a date is in Week A (0) or Week B (1).
    public mutating func setWeek(_ week: Int, for date: Date, calendar: Calendar) {
        let monday = Self.monday(of: date, calendar: calendar)
        weekAStart = calendar.date(byAdding: .day, value: -7 * (week % max(weekCount, 1)), to: monday) ?? monday
    }

    /// Whether a day falls in a term. Every day does when there are no terms.
    public func isInTerm(_ date: Date, calendar: Calendar) -> Bool {
        guard !terms.isEmpty else { return true }
        let day = calendar.startOfDay(for: date)
        return terms.contains { calendar.startOfDay(for: $0.start) <= day && day <= calendar.startOfDay(for: $0.end) }
    }

    // MARK: Classes

    /// The lessons on a day: none in the holidays.
    public func lessons(on date: Date, calendar: Calendar) -> [Lesson] {
        guard isInTerm(date, calendar: calendar) else { return [] }
        let weekday = calendar.component(.weekday, from: date)
        let week = week(of: date, calendar: calendar)
        return lessons.filter { $0.week == week && $0.weekday == weekday }
    }

    /// Classes that overlap an interval, earliest first, titled like
    /// "Physics, Period 3". Lessons for subjects that are gone are left out.
    public func classes(in interval: DateInterval, subjects: [Subject], calendar: Calendar) -> [ClassSession] {
        let names = Dictionary(subjects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let periodsByID = Dictionary(periods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var classes: [ClassSession] = []
        for day in days(in: interval, calendar: calendar) {
            for lesson in lessons(on: day, calendar: calendar) {
                guard let name = names[lesson.subjectID],
                      let period = periodsByID[lesson.periodID],
                      let span = Self.interval(on: day, from: period.start, to: period.end, calendar: calendar),
                      span.end > interval.start, span.start < interval.end
                else { continue }
                classes.append(ClassSession(subjectID: lesson.subjectID, title: "\(name), \(period.name)", start: span.start, end: span.end))
            }
        }
        return classes.sorted { $0.start < $1.start }
    }

    /// Each day with classes, from the first bell to the last, free periods
    /// included. The planner keeps these free.
    public func schoolDays(in interval: DateInterval, calendar: Calendar) -> [DateInterval] {
        guard let first = periods.map(\.start).min(), let last = periods.map(\.end).max() else { return [] }
        return days(in: interval, calendar: calendar).compactMap { day in
            guard !lessons(on: day, calendar: calendar).isEmpty else { return nil }
            return Self.interval(on: day, from: first, to: last, calendar: calendar)
        }
    }

    // MARK: Editing

    /// The subject taught in a period on a day of Week A or B.
    public func subject(week: Int, weekday: Int, period: Period.ID) -> Subject.ID? {
        lessons.first { $0.week == week && $0.weekday == weekday && $0.periodID == period }?.subjectID
    }

    /// Puts a subject in a period, or makes it a free period with nil.
    public mutating func setSubject(_ subjectID: Subject.ID?, week: Int, weekday: Int, period: Period.ID) {
        lessons.removeAll { $0.week == week && $0.weekday == weekday && $0.periodID == period }
        if let subjectID {
            lessons.append(Lesson(week: week, weekday: weekday, periodID: period, subjectID: subjectID))
        }
    }

    /// Makes Week B the same as Week A.
    public mutating func copyWeekAToB() {
        lessons.removeAll { $0.week == 1 }
        lessons += lessons.filter { $0.week == 0 }.map { Lesson(week: 1, weekday: $0.weekday, periodID: $0.periodID, subjectID: $0.subjectID) }
    }

    /// Leaves out classes for periods and subjects that no longer exist, and
    /// Week B's when there's only one week.
    public func tidied(keeping subjects: Set<Subject.ID>) -> SchoolTimetable {
        var timetable = self
        let periodIDs = Set(periods.map(\.id))
        timetable.lessons = lessons.filter { periodIDs.contains($0.periodID) && subjects.contains($0.subjectID) && $0.week < weekCount }
        return timetable
    }

    // MARK: Days

    private func days(in interval: DateInterval, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    private static func interval(on day: Date, from start: Int, to end: Int, calendar: Calendar) -> DateInterval? {
        guard end > start,
              let from = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day),
              let to = calendar.date(bySettingHour: min(end, 24 * 60 - 1) / 60, minute: min(end, 24 * 60 - 1) % 60, second: 0, of: day)
        else { return nil }
        return DateInterval(start: from, end: to)
    }
}
