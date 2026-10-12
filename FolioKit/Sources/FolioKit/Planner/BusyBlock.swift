import Foundation

/// An event from the student's calendar, such as a lecture or a shift at work.
/// The app reads these with EventKit, so the planner and the timetable voter
/// can work with plain values and be tested without a real calendar.
public struct BusyBlock: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: String
    public var colorHex: UInt32
    public var location: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, calendarID: String, colorHex: UInt32 = 0x8E8E93, location: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.colorHex = colorHex
        self.location = location
    }

    public var interval: DateInterval {
        DateInterval(start: start, end: max(start, end))
    }
}
