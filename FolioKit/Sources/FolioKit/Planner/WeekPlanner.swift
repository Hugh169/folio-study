import Foundation

/// Fits study sessions into the student's study windows, around anything busy:
/// events from their calendar, exams and, for school students, school hours or
/// their timetable's school days.
///
/// Work for assessments comes first. Each open assessment's remaining hours are
/// spread over the days before it's due, ramping up as it gets closer, and this
/// week gets its share. Then every subject gets a session with the time left,
/// and the subject's to-dos go into its sessions.
///
/// Sessions the student made or changed stay where they are: new ones fit
/// around them, and they count towards the work they're for.
public struct WeekPlanner: Sendable {
    public var calendar: Calendar
    public var preferences: StudyPreferences
    /// Replaces school hours when set: only days with classes are kept free,
    /// so the holidays are open for study.
    public var timetable: SchoolTimetable?

    public init(calendar: Calendar, preferences: StudyPreferences = StudyPreferences(), timetable: SchoolTimetable? = nil) {
        self.calendar = calendar
        self.preferences = preferences
        self.timetable = timetable
    }

    public struct Result: Sendable {
        public var sessions: [StudySession]
        public var added: Int
        /// Steps from sessions the new plan replaced that no new session could
        /// take, such as when their subject gets no time this week.
        public var leftoverSteps: [LeftoverStep] = []
    }

    /// A step that needs a new home.
    public struct LeftoverStep: Hashable, Sendable {
        public var subjectID: Subject.ID
        public var assessmentID: Assessment.ID?
        public var step: PlanStep
    }

    /// - Parameters:
    ///   - busy: Timed events to plan around. Leave out all-day events, such
    ///     as holidays, which shouldn't block study time. Exams and tests in
    ///     `assessments` are added.
    ///   - todos: The student's to-dos. Open ones go into new sessions in their subject.
    public func plan(weekStart: Date, now: Date, subjects: [Subject], assessments: [Assessment], existing: [StudySession], busy: [DateInterval] = [], todos: [Todo] = []) -> Result {
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
            return Result(sessions: existing, added: 0)
        }

        // Keep sessions from other weeks, ones this week that have already started,
        // ones the student has recorded, such as one they started early, and
        // ones they made or changed.
        let isKept = { (session: StudySession) in
            session.isRecorded || session.isOwn || session.start < now || session.start >= weekEnd || session.end <= weekStart
        }
        let kept = existing.filter(isKept)
        let replaced = existing.filter { !isKept($0) }
        // Kept sessions still to come this week: new ones go around them, with a break between.
        let staying = kept.filter { $0.start < weekEnd && $0.end > max(now, weekStart) }
        let breakTime = TimeInterval(preferences.breakMinutes * 60)
        let shortest = TimeInterval(preferences.sessionMinutes * 60)
        let busy = busy + assessments.filter { !$0.isDone }.compactMap(\.sitting)

        var days: [Day] = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            let taken = staying.filter { calendar.isDate($0.start, inSameDayAs: date) }
            let around = taken.map { DateInterval(start: $0.start.addingTimeInterval(-breakTime), end: $0.end.addingTimeInterval(breakTime)) }
            let windows = Self.subtract(around, from: freeWindows(on: date, after: now, busy: busy)).filter { $0.duration >= shortest }
            return windows.isEmpty ? nil : Day(date: date, windows: windows, sessions: taken)
        }

        var added: [StudySession] = []
        func place(_ demand: Demand) {
            let candidates = days.indices
                .filter { days[$0].sessions.count < preferences.maxSessionsPerDay && !days[$0].has(demand) }
                .sorted { a, b in
                    if let target = demand.target {
                        let distanceA = abs(days[a].date.timeIntervalSince(target))
                        let distanceB = abs(days[b].date.timeIntervalSince(target))
                        if distanceA != distanceB { return distanceA < distanceB }
                        return days[a].date < days[b].date
                    }
                    return (days[a].sessions.count, days[a].date) < (days[b].sessions.count, days[b].date)
                }
            for index in candidates {
                guard let slot = days[index].nextSlot(minutes: demand.minutes, breakMinutes: preferences.breakMinutes),
                      slot.end <= (demand.dueBy ?? .distantFuture)
                else { continue }
                let session = StudySession(
                    subjectID: demand.subjectID,
                    start: slot.start,
                    end: slot.end,
                    assessmentID: demand.assessment?.id,
                    title: demand.assessment.map { title(for: $0, at: slot.start) }
                )
                days[index].sessions.append(session)
                added.append(session)
                return
            }
        }

        // Most urgent first.
        for assessment in assessments.sorted(by: { $0.due < $1.due }) where assessment.isOpen(at: now) {
            for demand in demands(for: assessment, weekStart: weekStart, weekEnd: weekEnd, now: now, existing: existing) {
                place(demand)
            }
        }

        // Then one session per subject, starting with the subjects that have the fewest so far,
        // so every subject gets time before any gets extra. A subject the student
        // made their own general session for this week already has its time.
        let plannedCount = { (id: Subject.ID) in added.filter { $0.subjectID == id }.count }
        let ownGeneral = Set(kept.filter { $0.isOwn && $0.assessmentID == nil && $0.start >= weekStart && $0.start < weekEnd }.map(\.subjectID))
        for subject in subjects.sorted(by: { plannedCount($0.id) < plannedCount($1.id) }) where !ownGeneral.contains(subject.id) {
            place(Demand(subjectID: subject.id, minutes: preferences.sessionMinutes))
        }

        // Steps planned in the sessions being replaced go to the new session
        // for the same work, so nothing the student meant to do is lost.
        // To-dos are placed again below, and cards are worked out afresh.
        var leftovers: [LeftoverStep] = []
        for old in replaced {
            let steps = old.plan.filter { !$0.isDone && $0.kind != .todo && $0.kind != .cards }
            guard !steps.isEmpty else { continue }
            if let index = added.firstIndex(where: { $0.subjectID == old.subjectID && $0.assessmentID == old.assessmentID })
                ?? added.firstIndex(where: { $0.subjectID == old.subjectID }) {
                added[index].plan.add(steps)
            } else {
                leftovers += steps.map { LeftoverStep(subjectID: old.subjectID, assessmentID: old.assessmentID, step: $0) }
            }
        }

        // To-dos go into the new sessions: one for an assessment into that
        // work's sessions, the rest into general study. A subject with more
        // to-dos than fit gets one more session for them, unless the student
        // made their own session for the subject, where Folio suggests them.
        let subjectIDs = Set(subjects.map(\.id))
        let alreadyPlanned = Set(staying.flatMap(\.plan).filter { $0.kind == .todo }.compactMap(\.reference))
        var waiting = todos
            .filter { !$0.isDone && subjectIDs.contains($0.subjectID) && !alreadyPlanned.contains($0.id.uuidString) }
            .sorted { $0.createdAt < $1.createdAt }
        let todoMinutes = Dictionary(todos.map { ($0.id.uuidString, $0.plannedMinutes) }, uniquingKeysWith: { first, _ in first })
        func room(in session: StudySession) -> Int {
            session.minutes - session.plan.filter { $0.kind == .todo }.reduce(0) { $0 + (todoMinutes[$1.reference ?? ""] ?? 0) }
        }
        /// Puts waiting to-dos into the new sessions that `fits` allows, while they have room.
        /// A session always takes one, however long it is.
        func fill(where fits: (StudySession, Todo) -> Bool) {
            waiting = waiting.filter { todo in
                let candidates = added.indices.filter { fits(added[$0], todo) }.sorted { added[$0].start < added[$1].start }
                guard let index = candidates.first(where: { room(in: added[$0]) >= todo.plannedMinutes || !added[$0].plan.contains { $0.kind == .todo } }) else { return true }
                added[index].plan.add([todo.step])
                return false
            }
        }
        fill { session, todo in todo.assessmentID != nil && session.assessmentID == todo.assessmentID }
        fill { session, todo in session.subjectID == todo.subjectID && session.assessmentID == nil }
        for subjectID in Set(waiting.map(\.subjectID)).subtracting(ownGeneral).sorted(by: { $0.uuidString < $1.uuidString }) {
            place(Demand(subjectID: subjectID, minutes: preferences.sessionMinutes))
        }
        fill { session, todo in session.subjectID == todo.subjectID && session.assessmentID == nil }

        return Result(sessions: kept + added, added: added.count, leftoverSteps: leftovers)
    }

    /// This week's share of the work left on an assessment, as sessions aimed
    /// at days spread through the week's part of its run-up.
    func demands(for assessment: Assessment, weekStart: Date, weekEnd: Date, now: Date, existing: [StudySession]) -> [Demand] {
        let done = existing.filter { $0.assessmentID == assessment.id }.reduce(0) { $0 + $1.minutesDone(at: now) }
        let remaining = Double(Int(assessment.plannedHours * 60) - done)
        // Nothing on the day it's due: that day is for handing in or sitting it.
        let workEnd = calendar.startOfDay(for: assessment.due)
        let today = calendar.startOfDay(for: now)
        guard remaining > 0, workEnd > today,
              let leadStart = assessment.workStart(calendar: calendar)
        else { return [] }
        let workStart = max(today, leadStart)

        // Every day of the run-up, weighted from 1 on the first day to 3 on the last.
        var runUp: [Date] = []
        var day = workStart
        while day < workEnd {
            runUp.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard !runUp.isEmpty else { return [] }
        let weight = { (index: Int) -> Double in
            runUp.count == 1 ? 1 : 1 + 2 * Double(index) / Double(runUp.count - 1)
        }
        let thisWeek = runUp.indices.filter { runUp[$0] >= weekStart && runUp[$0] < weekEnd }
        guard !thisWeek.isEmpty else { return [] }
        let total = runUp.indices.reduce(0) { $0 + weight($1) }
        // Sessions the student made for it this week cover part of the week's share.
        let ownPlanned = existing.filter {
            $0.assessmentID == assessment.id && $0.isOwn && !$0.isRecorded && $0.end > now && $0.start >= weekStart && $0.start < weekEnd
        }.reduce(0) { $0 + $1.minutes }
        let share = remaining * thisWeek.reduce(0) { $0 + weight($1) } / total - Double(ownPlanned)
        guard share > 0 else { return [] }

        let long = Double(preferences.longSessionMinutes)
        var minutes = share >= long ? preferences.longSessionMinutes : preferences.sessionMinutes
        var count = Int((share / Double(minutes)).rounded())
        if count == 0 && share >= Double(preferences.sessionMinutes) / 2 {
            count = 1
            minutes = preferences.sessionMinutes
        }
        count = min(count, thisWeek.count)
        guard count > 0 else { return [] }

        // Aim the sessions at days spread through this week's part of the run-up.
        return (0..<count).map { k in
            let position = Int(Double(k + 1) * Double(thisWeek.count) / Double(count + 1))
            let target = runUp[thisWeek[min(position, thisWeek.count - 1)]]
            return Demand(subjectID: assessment.subjectID, minutes: minutes, dueBy: workEnd, assessment: assessment, target: target)
        }
    }

    /// "Depth Study: Draft" when a milestone is coming up, or just the title.
    private func title(for assessment: Assessment, at date: Date) -> String {
        guard let milestone = assessment.nextMilestone(after: date) else { return assessment.title }
        return "\(assessment.title): \(milestone.title)"
    }

    struct Demand {
        var subjectID: Subject.ID
        var minutes: Int
        var dueBy: Date?
        var assessment: Assessment?
        /// The day it would best go on.
        var target: Date?
    }

    private struct Day {
        var date: Date
        var windows: [DateInterval]
        var sessions: [StudySession] = []

        /// Whether the day already has this work: the same assessment, or any
        /// session in the subject for general study.
        func has(_ demand: Demand) -> Bool {
            if let assessment = demand.assessment {
                return sessions.contains { $0.assessmentID == assessment.id }
            }
            return sessions.contains { $0.subjectID == demand.subjectID }
        }

        /// The first gap long enough for a session, leaving a break after the previous one.
        func nextSlot(minutes: Int, breakMinutes: Int) -> DateInterval? {
            let length = TimeInterval(minutes * 60)
            for window in windows {
                let lastEnd = sessions.filter { window.contains($0.start) }.map(\.end).max()
                let start = lastEnd.map { $0.addingTimeInterval(TimeInterval(breakMinutes * 60)) } ?? window.start
                if start.addingTimeInterval(length) <= window.end {
                    return DateInterval(start: start, duration: length)
                }
            }
            return nil
        }
    }

    /// The day's study windows, minus busy time (with a buffer either side),
    /// school, and anything already past.
    func freeWindows(on day: Date, after now: Date, busy: [DateInterval]) -> [DateInterval] {
        let weekday = calendar.component(.weekday, from: day)
        let spans = preferences.weekdays.contains(weekday) ? preferences.weekdayWindows : preferences.weekendWindows
        let windows = spans.compactMap { interval(on: day, from: $0.start, to: $0.end) }

        let buffer = TimeInterval(preferences.bufferMinutes * 60)
        var blocked = busy.map { DateInterval(start: $0.start.addingTimeInterval(-buffer), end: $0.end.addingTimeInterval(buffer)) }
        if let timetable {
            if let whole = calendar.dateInterval(of: .day, for: day) {
                blocked += timetable.schoolDays(in: whole, calendar: calendar)
            }
        } else if let school = preferences.schoolHours, school.weekdays.contains(weekday),
                  let hours = interval(on: day, from: school.start, to: school.end) {
            blocked.append(hours)
        }
        let earliest = roundedUpToHalfHour(now)
        if let dayStart = calendar.dateInterval(of: .day, for: day)?.start, earliest > dayStart {
            blocked.append(DateInterval(start: dayStart, end: earliest))
        }

        let minimum = TimeInterval(preferences.sessionMinutes * 60)
        return Self.subtract(blocked, from: windows).filter { $0.duration >= minimum }
    }

    private func interval(on day: Date, from start: Int, to end: Int) -> DateInterval? {
        guard end > start,
              let from = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day),
              let to = calendar.date(bySettingHour: min(end, 24 * 60 - 1) / 60, minute: min(end, 24 * 60 - 1) % 60, second: 0, of: day)
        else { return nil }
        return DateInterval(start: from, end: to)
    }

    /// `windows` with every busy interval cut out of them.
    static func subtract(_ busy: [DateInterval], from windows: [DateInterval]) -> [DateInterval] {
        var free = windows
        for block in busy {
            free = free.flatMap { window -> [DateInterval] in
                guard block.end > window.start, block.start < window.end else { return [window] }
                var pieces: [DateInterval] = []
                if block.start > window.start { pieces.append(DateInterval(start: window.start, end: block.start)) }
                if block.end < window.end { pieces.append(DateInterval(start: block.end, end: window.end)) }
                return pieces
            }
        }
        return free.sorted { $0.start < $1.start }
    }

    private func roundedUpToHalfHour(_ date: Date) -> Date {
        let step: TimeInterval = 30 * 60
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }
}
