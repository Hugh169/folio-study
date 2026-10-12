import FolioKit
import SwiftUI

extension AppModel {
    private static let plannedCalendarsKey = "plannedCalendarIDs"
    private static let timetableCalendarsKey = "timetableCalendarIDs"
    private static let usesRemindersKey = "usesReminders"

    // MARK: Connecting

    /// Picks up where the student left off: if they allowed Calendar or
    /// Reminders before, Folio reads them again without asking.
    func restoreCalendar() {
        guard let live else { return }
        let link = CalendarLink { [weak self] in self?.calendarChanged() }
        live.calendarLink = link
        if link.canReadCalendars {
            loadCalendars()
            loadEvents(around: .now, force: true)
        }
        usesReminders = live.defaults.bool(forKey: Self.usesRemindersKey) && link.canUseReminders
        checkCompletedReminders()
    }

    /// Asks macOS for permission to read the student's calendars.
    func connectCalendar() async {
        guard let link = live?.calendarLink else { return }
        if await link.requestCalendarAccess() {
            loadCalendars()
            loadEvents(around: .now, force: true)
        }
        calendarAccessRefused = link.calendarAccessWasRefused
    }

    private func loadCalendars() {
        guard let live, let link = live.calendarLink else { return }
        calendarList = link.calendars()
        isCalendarConnected = true
        if let saved = live.defaults.stringArray(forKey: Self.plannedCalendarsKey) {
            plannedCalendarIDs = Set(saved)
        } else {
            // Plan around everything except birthdays and holidays.
            plannedCalendarIDs = Set(calendarList.filter { !$0.isUsuallyIgnored }.map(\.id))
        }
        timetableCalendarIDs = Set(live.defaults.stringArray(forKey: Self.timetableCalendarsKey) ?? [])
    }

    /// Brings back the calendars a backup planned around, by ID, or by name
    /// and account on another Mac. Only possible once Calendar is connected.
    func restoreCalendarChoices(_ choices: [FolioBackup.CalendarChoice]) -> Bool {
        guard let live, isCalendarConnected, !choices.isEmpty else { return false }
        func match(_ choice: FolioBackup.CalendarChoice) -> String? {
            calendarList.first { $0.id == choice.id }?.id
                ?? calendarList.first { $0.title == choice.title && $0.account == choice.account }?.id
        }
        plannedCalendarIDs = Set(choices.filter(\.plansAround).compactMap(match))
        timetableCalendarIDs = Set(choices.filter(\.isTimetable).compactMap(match))
        live.defaults.set(Array(plannedCalendarIDs), forKey: Self.plannedCalendarsKey)
        live.defaults.set(Array(timetableCalendarIDs), forKey: Self.timetableCalendarsKey)
        loadEvents(around: .now, force: true)
        return true
    }

    /// Turns Reminders back on after a restore, if Folio is already allowed to use them.
    func restoreUsesReminders(_ on: Bool) -> Bool {
        guard let live, let link = live.calendarLink, on, link.canUseReminders else { return false }
        usesReminders = true
        live.defaults.set(true, forKey: Self.usesRemindersKey)
        return true
    }

    /// Loads events from four weeks before `date` to twelve weeks after, unless
    /// that week is already loaded.
    func loadEvents(around date: Date, force: Bool = false) {
        guard let live, let link = live.calendarLink, isCalendarConnected else { return }
        let week = weekStart(containing: date)
        if !force, let loaded = live.loadedEventRange, loaded.contains(week),
           let weekEnd = calendar.date(byAdding: .day, value: 7, to: week), loaded.contains(weekEnd) {
            return
        }
        guard let start = calendar.date(byAdding: .weekOfYear, value: -4, to: week),
              let end = calendar.date(byAdding: .weekOfYear, value: 16, to: start)
        else { return }
        let range = DateInterval(start: start, end: end)
        calendarEvents = link.events(in: range, calendarIDs: plannedCalendarIDs)
        live.loadedEventRange = range
        updateTimetable(link.events(in: range, calendarIDs: timetableCalendarIDs))
    }

    func setPlansAround(_ info: CalendarInfo, _ on: Bool) {
        if on { plannedCalendarIDs.insert(info.id) } else { plannedCalendarIDs.remove(info.id) }
        live?.defaults.set(Array(plannedCalendarIDs), forKey: Self.plannedCalendarsKey)
        loadEvents(around: .now, force: true)
    }

    func setTimetable(_ info: CalendarInfo, _ on: Bool) {
        if on { timetableCalendarIDs.insert(info.id) } else { timetableCalendarIDs.remove(info.id) }
        live?.defaults.set(Array(timetableCalendarIDs), forKey: Self.timetableCalendarsKey)
        loadEvents(around: .now, force: true)
    }

    private func calendarChanged() {
        guard live?.calendarLink?.canReadCalendars == true || usesReminders else { return }
        if live?.calendarLink?.canReadCalendars == true {
            loadCalendars()
            loadEvents(around: live?.loadedEventRange.map { $0.start.addingTimeInterval($0.duration / 4) } ?? .now, force: true)
        }
        checkCompletedReminders()
    }

    // MARK: Reminders

    /// Mirrors assessments to a "Folio" list in Reminders, asking macOS the first time.
    /// Turning it off leaves the reminders already made, since they're the student's now.
    func setUsesReminders(_ on: Bool) async {
        guard let live, let link = live.calendarLink else { return }
        if on {
            guard await link.requestRemindersAccess() else {
                remindersAccessRefused = link.remindersAccessWasRefused
                return
            }
        }
        usesReminders = on
        live.defaults.set(on, forKey: Self.usesRemindersKey)
        if on {
            for assessment in assessments where !assessment.isDone {
                syncReminder(for: assessment)
            }
        }
    }

    func syncReminder(for assessment: Assessment) {
        guard usesReminders, let live, let link = live.calendarLink, let record = live.store.assessmentRecord(assessment.id) else { return }
        do {
            record.reminderID = try link.saveReminder(
                id: record.reminderID,
                title: assessment.title,
                subject: subject(assessment.subjectID)?.name ?? "",
                due: assessment.due,
                isDone: assessment.isDone
            )
            live.store.save()
        } catch {
            alert = AlertMessage(title: "Couldn't update Reminders", detail: error.localizedDescription)
        }
    }

    func removeReminder(id: String?) {
        guard usesReminders, let id, let link = live?.calendarLink else { return }
        try? link.removeReminder(id: id)
    }

    /// Assessments ticked off in Reminders are marked submitted in Folio too.
    private func checkCompletedReminders() {
        guard usesReminders, let live, let link = live.calendarLink else { return }
        let open = live.store.assessmentRecords().filter { !$0.isDone && $0.reminderID != nil }
        let completed = link.completedReminders(among: Set(open.compactMap(\.reminderID)))
        guard !completed.isEmpty else { return }
        for record in open where completed.contains(record.reminderID ?? "") {
            var assessment = record.assessment
            assessment.isDone = true
            record.update(from: assessment)
            if let index = assessments.firstIndex(where: { $0.id == record.id }) {
                assessments[index] = assessment
            }
        }
        live.store.save()
    }

    // MARK: Timetable

    /// Keeps the timetable's events, and passes their classes to the class-time signal.
    func updateTimetable(_ events: [BusyBlock]) {
        timetableEvents = events
        refreshClasses()
    }
}
