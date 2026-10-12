import Foundation

/// Ideas for what to do in a study session, from what Folio already knows:
/// where the student got up to last time, the assessment's next step, the
/// subject's to-dos, flashcards that are due and a past paper not yet
/// practised. The student picks the ones they want.
public enum PlanSuggestions {
    /// A past paper to suggest.
    public struct Paper: Hashable, Sendable {
        /// Such as "2023 HSC · Paper 2".
        public var title: String
        public var fileName: String

        public init(title: String, fileName: String) {
            self.title = title
            self.fileName = fileName
        }
    }

    /// The longest a note from last time is quoted.
    static let noteLength = 90
    /// The most to-dos suggested at once.
    static let todoCount = 3

    /// - Parameters:
    ///   - previous: The last session for the same work that's over, for where the student got up to.
    ///   - todos: The student's to-dos; open ones in the session's subject are suggested.
    ///   - dueCards: Flashcards due in the subject.
    ///   - paper: A past paper in the subject the student hasn't practised.
    public static func suggestions(
        for session: StudySession,
        assessment: Assessment?,
        previous: StudySession?,
        todos: [Todo],
        dueCards: Int,
        paper: Paper?,
        now: Date
    ) -> [PlanStep] {
        var steps: [PlanStep] = []

        if let note = previous?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            let quoted = note.count > noteLength ? String(note.prefix(noteLength - 1)).trimmingCharacters(in: .whitespaces) + "…" : note
            steps.append(PlanStep(title: String(localized: "Pick up from last time: \(quoted)", bundle: .module), kind: .pickUp))
        }

        if let assessment, let milestone = assessment.nextMilestone(after: now) {
            steps.append(PlanStep(
                title: String(localized: "\(milestone.title) for \(assessment.title)", bundle: .module, comment: "A step such as “Draft for Depth Study”"),
                kind: .milestone,
                reference: milestone.id.uuidString
            ))
        }

        // To-dos for this work first, then the subject's general ones.
        let open = todos.filter { !$0.isDone && $0.subjectID == session.subjectID }.sorted { $0.createdAt < $1.createdAt }
        let forThisWork = session.assessmentID.map { id in open.filter { $0.assessmentID == id } } ?? []
        let general = open.filter { $0.assessmentID == nil }
        steps += (forThisWork + general).prefix(todoCount).map(\.step)

        if dueCards > 0 {
            steps.append(PlanStep(title: String(localized: "Review \(dueCards) cards", bundle: .module, comment: "A step: review the subject's flashcards that are due"), kind: .cards))
        }

        // Papers are practice for exams and tests, not for writing a task.
        if let paper, assessment == nil || assessment?.isSitting == true {
            steps.append(PlanStep(
                title: String(localized: "Practise a past paper: \(paper.title)", bundle: .module, comment: "A step such as “Practise a past paper: 2023 HSC · Paper 1”"),
                kind: .paper,
                reference: paper.fileName
            ))
        }

        return steps.filter { step in !session.plan.contains { $0.isSame(as: step) } }
    }
}

extension Array where Element == StudySession {
    /// Where the steps `finished` didn't get to go: the next session for the
    /// same work that hasn't started yet, or else the subject's next general
    /// session, or its next session of any kind.
    public func indexForCarrying(from finished: StudySession, now: Date) -> Int? {
        let upcoming = indices
            .filter { self[$0].id != finished.id && self[$0].subjectID == finished.subjectID && !self[$0].isRecorded && self[$0].start >= now }
            .sorted { self[$0].start < self[$1].start }
        let sameWork = finished.assessmentID.flatMap { id in upcoming.first { self[$0].assessmentID == id } }
        return sameWork ?? upcoming.first(where: { self[$0].assessmentID == nil }) ?? upcoming.first
    }

    /// Moves the steps `finished` didn't get to into the session from
    /// `indexForCarrying`. Returns the steps that had nowhere to go.
    public mutating func carrySteps(of finished: StudySession, now: Date) -> [PlanStep] {
        let steps = finished.unfinishedSteps
        guard !steps.isEmpty else { return [] }
        guard let target = indexForCarrying(from: finished, now: now) else { return steps }
        self[target].plan.add(steps.map { step in
            var moved = step
            moved.id = UUID()
            return moved
        })
        return []
    }
}
