import EventKit
import FolioKit
import Foundation

/// A calendar in Apple Calendar, as Settings lists it.
struct CalendarInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var account: String
    var colorHex: UInt32
    /// Birthdays and holiday calendars, which don't make the student busy.
    var isUsuallyIgnored: Bool
}

/// Reads the student's Apple Calendar so Folio can plan around it, without
/// ever changing it, and keeps their assessments in a "Folio" list in Apple
/// Reminders. macOS asks the student before Folio can do either.
final class CalendarLink {
    static let remindersListName = "Folio"

    let store = EKEventStore()
    private var observer: (any NSObjectProtocol)?

    /// - Parameter onChange: Called when anything changes in Calendar or Reminders.
    init(onChange: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var canReadCalendars: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var canUseReminders: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Whether the student said no before, so only System Settings can change it.
    var calendarAccessWasRefused: Bool {
        [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event))
    }

    var remindersAccessWasRefused: Bool {
        [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder))
    }

    func requestCalendarAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func requestRemindersAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    // MARK: Calendar

    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event)
            .map { calendar in
                CalendarInfo(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    account: calendar.source?.title ?? "",
                    colorHex: Self.hex(calendar.cgColor),
                    isUsuallyIgnored: calendar.type == .birthday
                        || (calendar.type == .subscription && calendar.title.localizedCaseInsensitiveContains("holiday"))
                )
            }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Events that make the student busy: ones marked Free and cancelled ones are left out.
    func events(in interval: DateInterval, calendarIDs: Set<String>) -> [BusyBlock] {
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return store.events(matching: predicate)
            .filter { $0.availability != .free && $0.status != .canceled }
            .map { event in
                BusyBlock(
                    id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSinceReferenceDate)",
                    title: event.title ?? String(localized: "Busy", comment: "An event in the student's calendar with no title"),
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarID: event.calendar.calendarIdentifier,
                    colorHex: Self.hex(event.calendar.cgColor),
                    location: event.location
                )
            }
    }

    // MARK: Reminders

    /// Folio's own list in Reminders, made the first time it's needed, in the
    /// student's default account so it reaches their iPhone through iCloud.
    private func folioList() throws -> EKCalendar {
        if let list = store.calendars(for: .reminder).first(where: { $0.title == Self.remindersListName }) {
            return list
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.remindersListName
        list.cgColor = CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
        guard let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw CocoaError(.featureUnsupported)
        }
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }

    /// Adds or updates an assessment's reminder, with alerts the day before at
    /// 9 am and two hours before. Returns the reminder's identifier.
    func saveReminder(id: String?, title: String, subject: String, due: Date, isDone: Bool) throws -> String {
        let reminder = id.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder } ?? EKReminder(eventStore: store)
        if reminder.calendar == nil {
            reminder.calendar = try folioList()
        }
        reminder.title = title
        reminder.notes = "\(subject) · added by Folio"
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        reminder.isCompleted = isDone
        reminder.alarms = Self.alarms(before: due).map { EKAlarm(absoluteDate: $0) }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func removeReminder(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    /// Whether a reminder Folio added is still in Reminders.
    func reminderExists(id: String) -> Bool {
        store.calendarItem(withIdentifier: id) is EKReminder
    }

    /// Which of these reminders the student has ticked off in Reminders.
    func completedReminders(among ids: Set<String>) -> Set<String> {
        ids.filter { (store.calendarItem(withIdentifier: $0) as? EKReminder)?.isCompleted == true }
    }

    /// Removes the reminders Folio added, then its "Folio" list if nothing the
    /// student added is left in it. Returns how many reminders went, and
    /// whether the list did.
    func removeFolioReminders(ids: [String]) async -> (reminders: Int, list: Bool) {
        var removed = 0
        for id in ids {
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { continue }
            if (try? store.remove(reminder, commit: false)) != nil { removed += 1 }
        }
        try? store.commit()
        guard let list = store.calendars(for: .reminder).first(where: { $0.title == Self.remindersListName }) else { return (removed, false) }
        let predicate = store.predicateForReminders(in: [list])
        let left = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0?.count ?? 1) }
        }
        guard left == 0 else { return (removed, false) }
        return (removed, (try? store.removeCalendar(list, commit: true)) != nil)
    }

    /// The day before at 9 am, and two hours before, leaving out any that have passed.
    static func alarms(before due: Date, now: Date = .now, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: due),
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore) {
            dates.append(morning)
        }
        dates.append(due.addingTimeInterval(-2 * 60 * 60))
        return dates.filter { $0 > now && $0 < due }
    }

    private static func hex(_ color: CGColor?) -> UInt32 {
        guard let color, let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count >= 3
        else { return 0x8E8E93 }
        let channel = { (value: CGFloat) in UInt32(max(0, min(255, (value * 255).rounded()))) }
        return channel(parts[0]) << 16 | channel(parts[1]) << 8 | channel(parts[2])
    }
}
