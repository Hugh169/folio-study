import Foundation

/// Something the student is marked on: a task, an exam or a test. The planner
/// works back from these, and files are linked to them.
public struct Assessment: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// An assignment, essay, project, report or investigation.
        case task
        /// Everyday work set in class, such as questions or reading: an hour
        /// or so, done in the few days before it's due.
        case homework
        case exam
        /// A quiz or in-class test.
        case test
        case presentation
        case practical
        case other
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case notStarted
        case inProgress
        case submitted
        case marked
    }

    /// A result: a score out of a total, a grade such as "A" or "Band 6", or both.
    public struct Mark: Hashable, Codable, Sendable {
        public var score: Double?
        public var outOf: Double?
        public var grade: String?

        public init(score: Double? = nil, outOf: Double? = nil, grade: String? = nil) {
            self.score = score
            self.outOf = outOf
            self.grade = grade
        }

        /// The score as a fraction of the total, such as 0.72 for 18/25.
        public var fraction: Double? {
            guard let score, let outOf, outOf > 0 else { return nil }
            return score / outOf
        }
    }

    /// A step on the way, such as a draft, with the date it should be done by.
    public struct Milestone: Identifiable, Hashable, Codable, Sendable {
        public var id: UUID
        public var title: String
        public var date: Date
        public var isDone: Bool

        public init(id: UUID = UUID(), title: String, date: Date, isDone: Bool = false) {
            self.id = id
            self.title = title
            self.date = date
            self.isDone = isDone
        }
    }

    /// Where Folio learned about it.
    public enum Source: String, Codable, Sendable {
        case typed
        case file
        case calendar

        /// A source this version doesn't know, such as one saved by a test
        /// build, reads as typed in, so the assessment still loads.
        public init(from decoder: any Decoder) throws {
            self = Source(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .typed
        }
    }

    public var id: UUID
    public var title: String
    public var subjectID: Subject.ID
    public var kind: Kind
    /// When it's due, or when an exam or test starts.
    public var due: Date
    /// How long an exam or test lasts.
    public var lengthMinutes: Int?
    public var room: String?
    /// How much it counts towards the course, as a percentage.
    public var weighting: Double?
    /// The marks it's out of, such as 40, when the task sheet says.
    public var totalMarks: Double?
    public var status: Status
    public var mark: Mark?
    public var feedback: String
    public var notes: String
    /// The student's own estimate of the work, in hours. `nil` uses `defaultEstimateHours`.
    public var estimateHours: Double?
    public var milestones: [Milestone]
    public var source: Source
    /// Its ID in the place it came from, such as a calendar event.
    public var externalID: String?
    /// When the mark was entered, so a weekly review can say what came back.
    public var markedAt: Date?
    /// The day to start work on it, when the student chose one, such as to
    /// get ahead of a busy week. Otherwise work starts `leadDays` before it's due.
    public var planFrom: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        subjectID: Subject.ID,
        kind: Kind = .task,
        due: Date,
        lengthMinutes: Int? = nil,
        room: String? = nil,
        weighting: Double? = nil,
        totalMarks: Double? = nil,
        status: Status = .notStarted,
        mark: Mark? = nil,
        feedback: String = "",
        notes: String = "",
        estimateHours: Double? = nil,
        milestones: [Milestone] = [],
        source: Source = .typed,
        externalID: String? = nil,
        markedAt: Date? = nil,
        planFrom: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.subjectID = subjectID
        self.kind = kind
        self.due = due
        self.lengthMinutes = lengthMinutes
        self.room = room
        self.weighting = weighting
        self.totalMarks = totalMarks
        self.status = status
        self.mark = mark
        self.feedback = feedback
        self.notes = notes
        self.estimateHours = estimateHours
        self.milestones = milestones
        self.source = source
        self.externalID = externalID
        self.markedAt = markedAt
        self.planFrom = planFrom
    }

    /// Handed in or marked. A ticked-off reminder marks it submitted.
    public var isDone: Bool {
        get { status == .submitted || status == .marked }
        set {
            if newValue {
                if !isDone { status = .submitted }
            } else if isDone {
                status = .inProgress
            }
        }
    }

    /// Exams and tests happen at a time; tasks are handed in by one.
    public var isSitting: Bool {
        kind == .exam || kind == .test
    }

    /// When an exam or test takes place, so nothing else is planned then.
    public var sitting: DateInterval? {
        guard isSitting else { return nil }
        return DateInterval(start: due, duration: TimeInterval((lengthMinutes ?? 60) * 60))
    }

    /// Whether there's still work to plan for it.
    public func isOpen(at now: Date) -> Bool {
        !isDone && due > now
    }

    /// The hours of work to plan, the student's own estimate or the default.
    public var plannedHours: Double {
        estimateHours ?? defaultEstimateHours
    }

    /// A first guess at the work from its kind and weighting: about 4 hours for
    /// every 10% of a task, a little more revision for an exam, and an hour
    /// for homework.
    public var defaultEstimateHours: Double {
        let hours: Double = switch kind {
        case .task: max(3, (weighting ?? 15) * 0.4)
        case .exam: max(4, (weighting ?? 25) * 0.4)
        case .test: max(2, (weighting ?? 5) * 0.4)
        case .presentation: max(2, (weighting ?? 15) * 0.3)
        case .practical: max(2, (weighting ?? 10) * 0.3)
        case .homework: 1
        case .other: 2
        }
        return (hours * 2).rounded() / 2
    }

    /// The first day of work on it: the day the student chose, or `leadDays`
    /// before the day it's due.
    public func workStart(calendar: Calendar) -> Date? {
        if let planFrom { return calendar.startOfDay(for: planFrom) }
        return calendar.date(byAdding: .day, value: -leadDays, to: calendar.startOfDay(for: due))
    }

    /// How many days before it's due the planner starts on it.
    public var leadDays: Int {
        switch kind {
        case .task, .exam: 21
        case .presentation: 14
        case .test, .practical, .other: 7
        case .homework: 3
        }
    }

    /// Suggested steps for a task, dated back from when it's due:
    /// start, a draft and a final check.
    public static func suggestedMilestones(for kind: Kind, due: Date, now: Date = .now, calendar: Calendar = .current) -> [Milestone] {
        guard kind == .task || kind == .presentation else { return [] }
        let steps: [(LocalizedStringResource, Int)] = [
            (LocalizedStringResource("Start", bundle: .module, comment: "A milestone: begin work on a task"), 14),
            (LocalizedStringResource("Draft", bundle: .module, comment: "A milestone: a first draft of a task"), 5),
            (LocalizedStringResource("Final check", bundle: .module, comment: "A milestone: check the task before handing it in"), 1),
        ]
        let startOfToday = calendar.startOfDay(for: now)
        return steps.compactMap { title, daysBefore in
            guard let day = calendar.date(byAdding: .day, value: -daysBefore, to: calendar.startOfDay(for: due)),
                  day >= startOfToday,
                  let date = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day)
            else { return nil }
            return Milestone(title: String(localized: title), date: date)
        }
    }

    /// The next step not yet done on or after `date`.
    public func nextMilestone(after date: Date) -> Milestone? {
        milestones.filter { !$0.isDone && $0.date >= date }.min { $0.date < $1.date }
    }
}

/// What a file is to an assessment.
public enum FileRole: String, Codable, Sendable, CaseIterable {
    /// The notification or task sheet that sets it.
    case taskSheet
    /// Marking criteria, guidelines or a rubric.
    case criteria
    case resource
    case draft
    case submitted
    /// The marked work handed back.
    case returned
}
