import FolioKit
import SwiftUI

/// A group of subjects to sum up as a term: the subjects archived under one
/// term name, or a term from the school timetable that's over.
struct TermRequest: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var subjectIDs: [Subject.ID]
    /// The term's dates, when the timetable has them.
    var range: DateInterval?
}

extension AppModel {
    // MARK: Marks

    func standing(of subjectID: Subject.ID) -> Standing {
        Standing(assessments: assessments(of: subjectID))
    }

    /// Every current subject's marks together.
    var overallStanding: Standing {
        let current = Set(subjects.map(\.id))
        return Standing(assessments: assessments.filter { current.contains($0.subjectID) })
    }

    // MARK: Study time

    /// How many weeks back study time looks.
    static let studyTimeWeeks = 4

    /// Each current subject's study over the last four weeks, against the
    /// plan and against its share of what's due in the next six.
    func studyTimes(now: Date = .now) -> [StudyTime] {
        let thisWeek = weekStart(containing: now)
        let start = calendar.date(byAdding: .weekOfYear, value: -(Self.studyTimeWeeks - 1), to: thisWeek) ?? thisWeek
        let dueBy = calendar.date(byAdding: .weekOfYear, value: 6, to: now) ?? now
        return StudyTime.compute(
            subjectIDs: subjects.map(\.id), sessions: sessions, assessments: assessments,
            period: DateInterval(start: start, end: max(start, now)), dueBy: dueBy, now: now
        )
    }

    // MARK: Weekly review

    private static let reviewedWeekKey = "lastWeeklyReview"
    private static let reviewReminderKey = "remindsWeeklyReview"

    /// The week a review looks back on: this one from Sunday midday, when it's
    /// nearly over, otherwise the week before.
    func reviewWeekStart(now: Date = .now) -> Date {
        let thisWeek = weekStart(containing: now)
        let isSunday = calendar.component(.weekday, from: now) == 1
        if isSunday && calendar.component(.hour, from: now) >= 12 { return thisWeek }
        return calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
    }

    func weekReview(startingOn weekStart: Date, now: Date = .now) -> WeekReview {
        WeekReview(weekStart: weekStart, calendar: calendar, sessions: sessions, assessments: assessments, todos: todos, now: now)
    }

    /// Whether Today should offer the week's review: from Sunday midday to
    /// Tuesday, until the student has looked at it, and only once they've
    /// planned or recorded something.
    func isWeeklyReviewWaiting(now: Date = .now) -> Bool {
        let weekday = calendar.component(.weekday, from: now)
        let isReviewTime = (weekday == 1 && calendar.component(.hour, from: now) >= 12) || weekday == 2 || weekday == 3
        guard isReviewTime else { return false }
        let week = reviewWeekStart(now: now)
        let reviewed = settings.object(forKey: Self.reviewedWeekKey) as? Date
        guard reviewed.map({ !calendar.isDate($0, inSameDayAs: week) }) ?? true else { return false }
        let end = calendar.date(byAdding: .day, value: 7, to: week) ?? week
        return sessions.contains { $0.start >= week && $0.start < end }
    }

    func markWeekReviewed(_ weekStart: Date) {
        settings.set(weekStart, forKey: Self.reviewedWeekKey)
    }

    /// Whether Folio reminds the student on Sunday evening to look back on their week.
    var remindsWeeklyReview: Bool {
        get { settings.bool(forKey: Self.reviewReminderKey) }
        set {
            settings.set(newValue, forKey: Self.reviewReminderKey)
            if newValue {
                Task { await scheduleWeeklyReviewReminder() }
            } else {
                live?.notifier.cancelWeeklyReview()
            }
        }
    }

    /// Asks for notifications the first time, then sets the Sunday reminder.
    func scheduleWeeklyReviewReminder() async {
        guard let notifier = live?.notifier else { return }
        var allowed = await notifier.isAllowed()
        if !allowed {
            allowed = await notifier.requestPermission()
            notificationsAllowed = allowed
        }
        if allowed { notifier.scheduleWeeklyReview() }
    }

    // MARK: Busy weeks

    private static let dismissedWarningsKey = "dismissedWorkloadWeeks"

    /// Weeks ahead with too much on, leaving out ones the student dismissed.
    func workloadWarnings(now: Date = .now) -> [WorkloadCheck.Warning] {
        let planner = WeekPlanner(calendar: calendar, preferences: profile.studyPreferences, timetable: profile.timetable)
        let dismissed = (settings.array(forKey: Self.dismissedWarningsKey) as? [Double] ?? []).map(Date.init(timeIntervalSinceReferenceDate:))
        return WorkloadCheck(planner: planner)
            .warnings(assessments: assessments.filter { subject($0.subjectID)?.isArchived == false }, sessions: sessions, now: now)
            .filter { warning in !dismissed.contains { calendar.isDate($0, inSameDayAs: warning.week.start) } }
    }

    func dismissWarning(_ warning: WorkloadCheck.Warning) {
        var dismissed = settings.array(forKey: Self.dismissedWarningsKey) as? [Double] ?? []
        dismissed.append(warning.week.start.timeIntervalSinceReferenceDate)
        // Only weeks still to come matter.
        let cutoff = Date.now.addingTimeInterval(-14 * 86_400).timeIntervalSinceReferenceDate
        settings.set(dismissed.filter { $0 > cutoff }, forKey: Self.dismissedWarningsKey)
    }

    /// Starts the suggested assessments earlier, so Plan My Week spreads their
    /// work into the weeks before.
    func startEarlier(_ suggestions: [WorkloadCheck.Suggestion]) {
        for suggestion in suggestions {
            guard var assessment = assessment(suggestion.assessmentID) else { continue }
            assessment.planFrom = suggestion.from
            saveAssessment(assessment)
        }
    }

    // MARK: Terms

    /// Terms to look back on: subjects archived under each term name, newest
    /// first, then the timetable's terms that are over.
    func pastTerms(now: Date = .now) -> [TermRequest] {
        let archived = Dictionary(grouping: archivedSubjects) { $0.term ?? "" }
            .sorted { $0.key > $1.key }
            .map { term, subjects in
                TermRequest(title: term.isEmpty ? String(localized: "Earlier subjects") : term, subjectIDs: subjects.map(\.id))
            }
        let finished = (profile.timetable?.terms ?? [])
            .filter { $0.end < now }
            .sorted { $0.start > $1.start }
            .prefix(4)
            .map { term in
                TermRequest(
                    title: (term.start..<term.end).formatted(.interval.day().month(.abbreviated).year()),
                    subjectIDs: subjects.map(\.id),
                    range: DateInterval(start: term.start, end: calendar.date(byAdding: .day, value: 1, to: term.end) ?? term.end)
                )
            }
        return archived + finished
    }

    func termSummary(_ request: TermRequest) -> TermSummary {
        TermSummary(subjectIDs: request.subjectIDs, range: request.range, sessions: sessions, assessments: assessments, fileDates: fileDates())
    }

    /// When each subject's files were filed.
    private func fileDates() -> [Subject.ID: [Date]] {
        if let store = live?.store {
            return Dictionary(grouping: store.filedItems(), by: \.subjectID).mapValues { $0.map(\.filedAt) }
        }
        return Dictionary(grouping: recentlySorted, by: \.subjectID).mapValues { $0.map(\.sortedAt) }
    }
}
