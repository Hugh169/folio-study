import FolioKit
import SwiftUI

extension AppModel {
    /// "Uni folder" or "School folder", for labels.
    var libraryTitle: String {
        profile.level == .university ? String(localized: "Uni folder") : String(localized: "School folder")
    }

    /// "Good morning, Sam", when the student told Folio their name.
    var greeting: String? {
        guard let name = profile.studentName, !name.isEmpty else { return nil }
        let hour = calendar.component(.hour, from: .now)
        if hour < 12 { return String(localized: "Good morning, \(name)") }
        if hour < 17 { return String(localized: "Good afternoon, \(name)") }
        return String(localized: "Good evening, \(name)")
    }

    /// "Courses" at uni, "Subjects" at school.
    var subjectsTitle: String {
        profile.level == .university ? String(localized: "Courses") : String(localized: "Subjects")
    }

    /// "New Course" at uni, "New Subject" at school.
    var newSubjectTitle: String {
        profile.level == .university ? String(localized: "New Course") : String(localized: "New Subject")
    }

    /// The next term's name in the student's school system, such as
    /// "2027 Semester 1" at an Australian uni or "2026–27" in the UK.
    var suggestedTermName: String {
        let style = pack?.termStyle ?? (profile.level == .university ? .regional : .calendarYear)
        return style.nextName(calendar: calendar)
    }

    // MARK: Timetable calendars

    /// Courses found in the student's calendars over the next four weeks, and
    /// the calendars they were in, which are probably the timetable.
    func coursesInCalendar() -> (courses: [TimetableReader.Course], calendarIDs: Set<String>) {
        guard let link = live?.calendarLink, isCalendarConnected else { return ([], []) }
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .weekOfYear, value: 4, to: start) else { return ([], []) }
        let events = link.events(in: DateInterval(start: start, end: end), calendarIDs: Set(calendarList.map(\.id)))
            .filter { !$0.isAllDay && TimetableReader.code(in: $0.title) != nil }
        return (TimetableReader.courses(in: events.map(\.title)), Set(events.map(\.calendarID)))
    }

    /// Marks the calendars that hold courses as the timetable.
    func useAsTimetable(_ calendarIDs: Set<String>) {
        for info in calendarList where calendarIDs.contains(info.id) && !timetableCalendarIDs.contains(info.id) {
            setTimetable(info, true)
        }
    }

    /// A subject for a course: named by its code, which is what files and the
    /// timetable use, with the course's name as another name.
    static func subject(for course: TimetableReader.Course, colorHex: UInt32, term: String?) -> Subject {
        Subject(
            name: course.code,
            colorHex: colorHex,
            aliases: course.name.map { [$0] } ?? [],
            codes: [course.code],
            summary: course.name ?? "",
            term: term
        )
    }

    // MARK: Terms

    /// Starts a new term: optionally archives the current subjects (their
    /// folders stay where they are) and adds the new term's courses.
    func startNewTerm(named name: String, archivesCurrent: Bool, courses: [TimetableReader.Course]) {
        var profile = self.profile
        if archivesCurrent {
            for index in profile.subjects.indices where !profile.subjects[index].isArchived {
                profile.subjects[index].isArchived = true
            }
        }
        for course in courses where !profile.sortableSubjects.contains(where: { $0.codes.contains(course.code) || $0.name == course.code }) {
            profile.subjects.append(Self.subject(for: course, colorHex: unusedSubjectColour(among: profile.sortableSubjects), term: name))
        }
        self.profile = profile
        if case .subject(let id) = destination, subject(id)?.isArchived == true {
            destination = .library
        }
        refreshClasses()
    }

    func restoreSubject(_ subject: Subject) {
        guard let index = profile.subjects.firstIndex(where: { $0.id == subject.id }) else { return }
        profile.subjects[index].isArchived = false
        refreshClasses()
    }

    func archiveSubject(_ subject: Subject) {
        guard let index = profile.subjects.firstIndex(where: { $0.id == subject.id }) else { return }
        profile.subjects[index].isArchived = true
        refreshClasses()
    }
}
