import Foundation

public struct StudySession: Identifiable, Hashable, Codable, Sendable {
    /// How the student said it went, when they finished it with the timer.
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// Did what they meant to.
        case done
        /// Got some of it done.
        case partly
        /// Didn't get to it.
        case skipped
    }

    public var id: UUID
    public var subjectID: Subject.ID
    public var start: Date
    public var end: Date
    /// The assessment it's for, when it's work towards one.
    public var assessmentID: Assessment.ID?
    /// What it's for, such as "Depth Study: Draft". `nil` is general study.
    public var title: String?
    /// Minutes the student actually studied, once recorded.
    public var doneMinutes: Int?
    public var outcome: Outcome?
    /// What the student noted at the end, such as where they got up to.
    public var note: String?
    /// What the student means to do in it, ticked off as they go.
    public var plan: [PlanStep]
    /// Made or changed by the student, so Plan My Week leaves it where it is.
    public var isOwn: Bool

    public init(
        id: UUID = UUID(),
        subjectID: Subject.ID,
        start: Date,
        end: Date,
        assessmentID: Assessment.ID? = nil,
        title: String? = nil,
        doneMinutes: Int? = nil,
        outcome: Outcome? = nil,
        note: String? = nil,
        plan: [PlanStep] = [],
        isOwn: Bool = false
    ) {
        self.id = id
        self.subjectID = subjectID
        self.start = start
        self.end = end
        self.assessmentID = assessmentID
        self.title = title
        self.doneMinutes = doneMinutes
        self.outcome = outcome
        self.note = note
        self.plan = plan
        self.isOwn = isOwn
    }

    // Sessions saved before plans existed, such as in older backups, have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subjectID = try container.decode(Subject.ID.self, forKey: .subjectID)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        assessmentID = try container.decodeIfPresent(Assessment.ID.self, forKey: .assessmentID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        doneMinutes = try container.decodeIfPresent(Int.self, forKey: .doneMinutes)
        outcome = try container.decodeIfPresent(Outcome.self, forKey: .outcome)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        plan = try container.decodeIfPresent([PlanStep].self, forKey: .plan) ?? []
        isOwn = try container.decodeIfPresent(Bool.self, forKey: .isOwn) ?? false
    }

    /// How long it's planned for.
    public var minutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    /// Steps not ticked off yet that should go on to the next session:
    /// everything except reviewing cards, which is worked out again then, and
    /// where the student got up to, which their note replaces.
    public var unfinishedSteps: [PlanStep] {
        plan.filter { !$0.isDone && $0.kind != .cards && $0.kind != .pickUp }
    }

    /// Minutes of work it counts for once it's over: what was recorded, or the
    /// time planned. Sessions the student removed don't exist any more, so they don't count.
    public func minutesDone(at now: Date) -> Int {
        if outcome == .skipped { return 0 }
        if let doneMinutes { return doneMinutes }
        return end <= now ? Int(end.timeIntervalSince(start) / 60) : 0
    }

    /// Finished with the timer, or marked as skipped.
    public var isRecorded: Bool {
        doneMinutes != nil || outcome != nil
    }
}

/// One thing the student means to do in a study session, such as "Questions
/// 21–25 of the 2019 paper".
public struct PlanStep: Identifiable, Hashable, Codable, Sendable {
    /// Where a step came from, so Folio can keep it in step with what it's about.
    public enum Kind: String, Codable, Sendable {
        /// Typed by the student.
        case own
        /// A to-do from the subject's list; `reference` is its ID.
        case todo
        /// Reviewing the subject's flashcards that are due.
        case cards
        /// Practising a past paper; `reference` is its file name.
        case paper
        /// The assessment's next step, such as a draft; `reference` is its ID.
        case milestone
        /// Where the student got up to last time, from their note.
        case pickUp

        /// A kind this version doesn't know reads as the student's own.
        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .own
        }
    }

    public var id: UUID
    public var title: String
    public var isDone: Bool
    public var kind: Kind
    public var reference: String?

    public init(id: UUID = UUID(), title: String, isDone: Bool = false, kind: Kind = .own, reference: String? = nil) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.kind = kind
        self.reference = reference
    }

    /// Whether two steps are about the same thing, so the same step isn't
    /// added twice.
    public func isSame(as other: PlanStep) -> Bool {
        if kind == other.kind, kind != .own, reference != nil, reference == other.reference { return true }
        if kind == .cards, other.kind == .cards { return true }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(other.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

extension Array where Element == PlanStep {
    /// Adds the steps that aren't here already, in order.
    public mutating func add(_ steps: [PlanStep]) {
        for step in steps where !contains(where: { $0.isSame(as: step) }) {
            append(step)
        }
    }
}

/// When school runs, in minutes after midnight.
public struct SchoolHours: Hashable, Codable, Sendable {
    /// `Calendar` weekday numbers: Monday to Friday.
    public var weekdays: Set<Int>
    public var start: Int
    public var end: Int

    public init(weekdays: Set<Int> = [2, 3, 4, 5, 6], start: Int = 8 * 60 + 45, end: Int = 15 * 60 + 15) {
        self.weekdays = weekdays
        self.start = start
        self.end = end
    }
}
