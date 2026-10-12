import Foundation

/// Something to do for a subject that isn't an assessment of its own, such as
/// "Fix the feedback on Task 2" or "Copy up Tuesday's notes". Plan My Week puts
/// open to-dos into the subject's study sessions.
public struct Todo: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var subjectID: Subject.ID
    public var title: String
    /// The assessment it's part of, if any, so it goes into that work's sessions.
    public var assessmentID: Assessment.ID?
    /// About how long it takes, when the student said.
    public var minutes: Int?
    public var isDone: Bool
    public var createdAt: Date
    public var doneAt: Date?

    public init(
        id: UUID = UUID(),
        subjectID: Subject.ID,
        title: String,
        assessmentID: Assessment.ID? = nil,
        minutes: Int? = nil,
        isDone: Bool = false,
        createdAt: Date = .now,
        doneAt: Date? = nil
    ) {
        self.id = id
        self.subjectID = subjectID
        self.title = title
        self.assessmentID = assessmentID
        self.minutes = minutes
        self.isDone = isDone
        self.createdAt = createdAt
        self.doneAt = doneAt
    }

    /// The time it's planned for when the student didn't say.
    public static let usualMinutes = 20

    /// How long to allow for it in a session.
    public var plannedMinutes: Int {
        minutes ?? Self.usualMinutes
    }

    /// As a step in a session's plan.
    public var step: PlanStep {
        PlanStep(title: title, isDone: isDone, kind: .todo, reference: id.uuidString)
    }
}
