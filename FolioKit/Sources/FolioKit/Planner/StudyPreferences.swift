import Foundation

/// When and how the student likes to study. Plan My Week fits sessions into
/// these windows, around anything busy.
public struct StudyPreferences: Hashable, Codable, Sendable {
    /// A span of the day, in minutes after midnight.
    public struct Window: Hashable, Codable, Sendable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// `Calendar` weekday numbers that use `weekdayWindows`; the rest use `weekendWindows`.
    public var weekdays: Set<Int>
    public var weekdayWindows: [Window]
    public var weekendWindows: [Window]
    /// A normal session's length.
    public var sessionMinutes: Int
    /// The first session for something due soon is longer.
    public var longSessionMinutes: Int
    public var maxSessionsPerDay: Int
    public var breakMinutes: Int
    /// Time kept free before and after events, for getting there and back.
    public var bufferMinutes: Int
    /// Fixed school hours, for students without a timetable in their calendar.
    public var schoolHours: SchoolHours?

    public init(
        weekdays: Set<Int> = [2, 3, 4, 5, 6],
        weekdayWindows: [Window] = [Window(start: 16 * 60, end: 19 * 60 + 30)],
        weekendWindows: [Window] = [Window(start: 9 * 60, end: 12 * 60 + 30), Window(start: 14 * 60, end: 17 * 60)],
        sessionMinutes: Int = 60,
        longSessionMinutes: Int = 90,
        maxSessionsPerDay: Int = 3,
        breakMinutes: Int = 30,
        bufferMinutes: Int = 15,
        schoolHours: SchoolHours? = SchoolHours()
    ) {
        self.weekdays = weekdays
        self.weekdayWindows = weekdayWindows
        self.weekendWindows = weekendWindows
        self.sessionMinutes = sessionMinutes
        self.longSessionMinutes = longSessionMinutes
        self.maxSessionsPerDay = maxSessionsPerDay
        self.breakMinutes = breakMinutes
        self.bufferMinutes = bufferMinutes
        self.schoolHours = schoolHours
    }

    /// For university: classes come from the timetable calendar, so the days are open.
    public static let university = StudyPreferences(
        weekdayWindows: [Window(start: 9 * 60, end: 12 * 60 + 30), Window(start: 13 * 60 + 30, end: 18 * 60), Window(start: 19 * 60, end: 21 * 60)],
        weekendWindows: [Window(start: 10 * 60, end: 12 * 60 + 30), Window(start: 14 * 60, end: 17 * 60)],
        maxSessionsPerDay: 4,
        schoolHours: nil
    )

    // Missing fields fall back to defaults, so older settings files still load.
    public init(from decoder: any Decoder) throws {
        let defaults = StudyPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? defaults.weekdays
        weekdayWindows = try container.decodeIfPresent([Window].self, forKey: .weekdayWindows) ?? defaults.weekdayWindows
        weekendWindows = try container.decodeIfPresent([Window].self, forKey: .weekendWindows) ?? defaults.weekendWindows
        sessionMinutes = try container.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? defaults.sessionMinutes
        longSessionMinutes = try container.decodeIfPresent(Int.self, forKey: .longSessionMinutes) ?? defaults.longSessionMinutes
        maxSessionsPerDay = try container.decodeIfPresent(Int.self, forKey: .maxSessionsPerDay) ?? defaults.maxSessionsPerDay
        breakMinutes = try container.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? defaults.breakMinutes
        bufferMinutes = try container.decodeIfPresent(Int.self, forKey: .bufferMinutes) ?? defaults.bufferMinutes
        schoolHours = try container.decodeIfPresent(SchoolHours.self, forKey: .schoolHours)
    }
}
