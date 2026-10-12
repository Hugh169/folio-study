import Foundation

/// How a subject is going: its marks so far, each counted by how much of the
/// course it's worth.
public struct Standing: Sendable, Equatable {
    /// A mark with a score, for a chart.
    public struct Point: Sendable, Equatable, Identifiable {
        public var id: Assessment.ID
        public var subjectID: Subject.ID
        public var title: String
        /// When it was due or sat.
        public var date: Date
        /// The score as a fraction, such as 0.84.
        public var fraction: Double
        public var weighting: Double?
    }

    /// A mark given only as a grade, such as "Band 5".
    public struct Grade: Sendable, Equatable, Identifiable {
        public var id: Assessment.ID
        public var title: String
        public var grade: String
    }

    /// The marks with a score averaged by what each is worth, such as 0.78.
    public var average: Double?
    /// How much of the course is marked, in percent, when assessments say what they're worth.
    public var weightMarked: Double?
    /// Marks with a score, oldest first.
    public var points: [Point]
    /// Marks given only as grades, newest first.
    public var grades: [Grade]

    public var isEmpty: Bool { points.isEmpty && grades.isEmpty }

    /// - Parameter assessments: One subject's assessments, or every subject's for a standing overall.
    public init(assessments: [Assessment]) {
        let marked = assessments.filter { $0.mark != nil }
        points = marked
            .compactMap { assessment in
                assessment.mark?.fraction.map {
                    Point(id: assessment.id, subjectID: assessment.subjectID, title: assessment.title, date: assessment.due, fraction: $0, weighting: assessment.weighting)
                }
            }
            .sorted { $0.date < $1.date }
        grades = marked
            .filter { $0.mark?.fraction == nil }
            .sorted { $0.due > $1.due }
            .compactMap { assessment in assessment.mark?.grade.map { Grade(id: assessment.id, title: assessment.title, grade: $0) } }

        // A mark whose assessment doesn't say what it's worth counts as much as
        // the average of those that do, or all count the same when none do.
        let known = points.compactMap(\.weighting).filter { $0 > 0 }
        let usual = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        let weights = points.map { point in point.weighting.flatMap { $0 > 0 ? $0 : nil } ?? usual }
        let total = weights.reduce(0, +)
        average = total > 0 ? zip(points, weights).reduce(0) { $0 + $1.0.fraction * $1.1 } / total : nil
        let markedWeight = marked.compactMap(\.weighting).reduce(0, +)
        weightMarked = markedWeight > 0 ? min(100, markedWeight) : nil
    }
}

/// Time studied in a subject, against the time planned and against how much
/// of the work coming up is the subject's.
public struct StudyTime: Sendable, Equatable, Identifiable {
    public var id: Subject.ID { subjectID }
    public var subjectID: Subject.ID
    /// Minutes recorded with the timer or marked done.
    public var studied: Int
    /// Minutes planned in sessions that weren't skipped.
    public var planned: Int
    /// The subject's share of all the study recorded, from 0 to 1.
    public var studyShare: Double
    /// The subject's share of the hours of work for open assessments due soon, from 0 to 1.
    public var dueShare: Double

    /// The least study, in minutes, before shares say anything.
    public static let enoughToCompare = 120

    /// Times for each subject over `period`, with shares of the work due by `dueBy`.
    public static func compute(subjectIDs: [Subject.ID], sessions: [StudySession], assessments: [Assessment], period: DateInterval, dueBy: Date, now: Date) -> [StudyTime] {
        let inPeriod = sessions.filter { period.contains($0.start) }
        let studied = Dictionary(grouping: inPeriod, by: \.subjectID).mapValues { $0.reduce(0) { $0 + ($1.outcome == .skipped ? 0 : $1.doneMinutes ?? 0) } }
        let planned = Dictionary(grouping: inPeriod.filter { $0.outcome != .skipped }, by: \.subjectID).mapValues { $0.reduce(0) { $0 + $1.minutes } }
        let coming = assessments.filter { !$0.isDone && $0.due > now && $0.due <= dueBy }
        let work = Dictionary(grouping: coming, by: \.subjectID).mapValues { $0.reduce(0) { $0 + $1.plannedHours } }
        let totalStudied = subjectIDs.reduce(0) { $0 + (studied[$1] ?? 0) }
        let totalWork = subjectIDs.reduce(0) { $0 + (work[$1] ?? 0) }
        return subjectIDs.map { id in
            StudyTime(
                subjectID: id,
                studied: studied[id] ?? 0,
                planned: planned[id] ?? 0,
                studyShare: totalStudied > 0 ? Double(studied[id] ?? 0) / Double(totalStudied) : 0,
                dueShare: totalWork > 0 ? (work[id] ?? 0) / totalWork : 0
            )
        }
    }

    /// Whether the subject is getting much less of the student's time than
    /// its share of what's due, once there's enough study to tell.
    public func isBehind(totalStudied: Int) -> Bool {
        totalStudied >= Self.enoughToCompare && dueShare >= 0.15 && studyShare < dueShare / 2
    }
}

/// A week looked back on: what was studied against the plan, what was handed
/// in or missed, marks that came back, and what's due the week after.
public struct WeekReview: Sendable {
    public struct SubjectMinutes: Sendable, Equatable, Identifiable {
        public var id: Subject.ID { subjectID }
        public var subjectID: Subject.ID
        public var studied: Int
        public var planned: Int
    }

    public var week: DateInterval
    /// Minutes recorded with the timer or marked done.
    public var studied: Int
    /// Minutes planned in sessions that weren't skipped.
    public var planned: Int
    public var done: Int
    public var partly: Int
    public var skipped: Int
    /// Sessions that are over but weren't recorded either way.
    public var notRecorded: Int
    /// Each subject's study, most first.
    public var bySubject: [SubjectMinutes]
    /// Assessments due in the week that were handed in or sat.
    public var handedIn: [Assessment]
    /// Assessments due in the week that aren't marked as handed in.
    public var overdue: [Assessment]
    /// Assessments whose mark was entered in the week.
    public var marksBack: [Assessment]
    public var todosDone: Int
    /// Open assessments due the week after.
    public var dueNext: [Assessment]
    /// Minutes already planned the week after.
    public var plannedNext: Int

    public init(weekStart: Date, calendar: Calendar, sessions: [StudySession], assessments: [Assessment], todos: [Todo], now: Date) {
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let nextEnd = calendar.date(byAdding: .day, value: 7, to: end) ?? end
        week = DateInterval(start: weekStart, end: end)
        let inWeek = sessions.filter { $0.start >= weekStart && $0.start < end }
        studied = inWeek.reduce(0) { $0 + ($1.outcome == .skipped ? 0 : $1.doneMinutes ?? 0) }
        planned = inWeek.filter { $0.outcome != .skipped }.reduce(0) { $0 + $1.minutes }
        done = inWeek.filter { $0.outcome == .done }.count
        partly = inWeek.filter { $0.outcome == .partly }.count
        skipped = inWeek.filter { $0.outcome == .skipped }.count
        notRecorded = inWeek.filter { !$0.isRecorded && $0.end <= now }.count
        bySubject = Dictionary(grouping: inWeek, by: \.subjectID)
            .map { id, sessions in
                SubjectMinutes(
                    subjectID: id,
                    studied: sessions.reduce(0) { $0 + ($1.outcome == .skipped ? 0 : $1.doneMinutes ?? 0) },
                    planned: sessions.filter { $0.outcome != .skipped }.reduce(0) { $0 + $1.minutes }
                )
            }
            .sorted { ($0.studied, $0.planned) > ($1.studied, $1.planned) }
        let dueInWeek = assessments.filter { $0.due >= weekStart && $0.due < end }.sorted { $0.due < $1.due }
        handedIn = dueInWeek.filter(\.isDone)
        overdue = dueInWeek.filter { !$0.isDone && $0.due < now }
        marksBack = assessments.filter { $0.mark != nil && ($0.markedAt.map { $0 >= weekStart && $0 < end } ?? false) }.sorted { $0.due < $1.due }
        todosDone = todos.filter { $0.isDone && ($0.doneAt.map { $0 >= weekStart && $0 < end } ?? false) }.count
        dueNext = assessments.filter { !$0.isDone && $0.due >= end && $0.due < nextEnd }.sorted { $0.due < $1.due }
        plannedNext = sessions.filter { $0.start >= end && $0.start < nextEnd && $0.outcome != .skipped }.reduce(0) { $0 + $1.minutes }
    }
}

/// A term looked back on: for each subject, the time studied, the marks, the
/// work handed in and the files filed.
public struct TermSummary: Sendable {
    public struct Line: Sendable, Identifiable {
        public var id: Subject.ID { subjectID }
        public var subjectID: Subject.ID
        public var studied: Int
        public var standing: Standing
        public var handedIn: Int
        public var files: Int
    }

    public var lines: [Line]
    /// All the subjects' marks together.
    public var standing: Standing

    public var studied: Int { lines.reduce(0) { $0 + $1.studied } }
    public var files: Int { lines.reduce(0) { $0 + $1.files } }

    /// - Parameters:
    ///   - range: The term's dates, or `nil` for everything the subjects have.
    ///   - fileDates: When each subject's files were filed.
    public init(subjectIDs: [Subject.ID], range: DateInterval?, sessions: [StudySession], assessments: [Assessment], fileDates: [Subject.ID: [Date]]) {
        let inTerm = { (date: Date) in range?.contains(date) ?? true }
        let termAssessments = assessments.filter { subjectIDs.contains($0.subjectID) && inTerm($0.due) }
        lines = subjectIDs.map { id in
            let mine = termAssessments.filter { $0.subjectID == id }
            return Line(
                subjectID: id,
                studied: sessions.filter { $0.subjectID == id && inTerm($0.start) && $0.outcome != .skipped }.reduce(0) { $0 + ($1.doneMinutes ?? 0) },
                standing: Standing(assessments: mine),
                handedIn: mine.filter(\.isDone).count,
                files: (fileDates[id] ?? []).filter(inTerm).count
            )
        }
        standing = Standing(assessments: termAssessments)
    }
}
