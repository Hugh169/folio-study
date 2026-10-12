import FolioKit
import SwiftUI

extension AppModel {
    // MARK: Plan My Week

    /// Replaces the week's upcoming study sessions with a new plan and returns
    /// how many sessions were added. Sessions that have already started, and
    /// ones the student made or changed, are kept; timed events from the
    /// student's calendar are planned around; and to-dos go into the new
    /// sessions. Steps from a replaced session that no new one could take
    /// join the subject's to-do list.
    func planWeek(containing date: Date, now: Date = .now) -> Int {
        let planner = WeekPlanner(calendar: calendar, preferences: profile.studyPreferences, timetable: profile.timetable)
        let result = planner.plan(
            weekStart: weekStart(containing: date),
            now: now,
            subjects: subjects,
            assessments: assessments,
            existing: sessions,
            busy: calendarEvents.filter { !$0.isAllDay }.map(\.interval),
            todos: todos
        )
        sessions = result.sessions
        saveSessions()
        for leftover in result.leftoverSteps where leftover.step.kind == .own {
            addTodo(leftover.step.title, subjectID: leftover.subjectID, assessmentID: leftover.assessmentID, now: now)
        }
        return result.added
    }

    /// The start of the week that "plan my week" should plan: this one, or
    /// from midday on its last day, when there's little of it left, the next.
    func weekToPlan(now: Date = .now) -> Date {
        let thisWeek = weekStart(containing: now)
        guard let lastDay = calendar.date(byAdding: .day, value: 6, to: thisWeek),
              let midday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: lastDay),
              now >= midday,
              let nextWeek = calendar.date(byAdding: .day, value: 7, to: thisWeek)
        else { return thisWeek }
        return nextWeek
    }

    /// The study session on now, or the next one today or later, leaving out
    /// ones the student already finished or skipped.
    func nextSession(after now: Date = .now) -> StudySession? {
        sessions.filter { $0.end > now && !$0.isRecorded }.min { $0.start < $1.start }
    }

    /// Loads saved sessions and assessments.
    func loadPlanner() {
        guard let live else { return }
        sessions = live.store.plannedSessions().map(\.session)
        assessments = live.store.assessmentRecords().map(\.assessment)
        live.librarian?.update(assessments: assessments)
    }
}
