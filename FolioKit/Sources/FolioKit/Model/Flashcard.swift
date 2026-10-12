import Foundation

/// A question and its answer for revising, made from one of the student's
/// files or typed in. Cards come back on a Leitner schedule: one the student
/// knew moves up a box and waits longer before it's asked again; one they
/// didn't know goes back to the first box, which comes round every day.
public struct Flashcard: Identifiable, Hashable, Codable, Sendable {
    /// Who wrote it.
    public enum Origin: String, Codable, Sendable {
        /// The on-device AI, from the student's file.
        case onDevice
        /// Claude, from the student's file, with their own key.
        case claude
        /// The student.
        case student
    }

    public var id: UUID
    public var subjectID: Subject.ID
    public var question: String
    public var answer: String
    /// The filed file it was made from, so the student can check the answer there.
    public var sourceID: UUID?
    /// That file's name when the card was made.
    public var sourceName: String?
    /// The words in the file that give the answer.
    public var quote: String?
    /// The assessment the student was revising for, if any.
    public var assessmentID: Assessment.ID?
    public var origin: Origin
    /// From 1, asked every day, to 5, asked once a month.
    public var box: Int
    /// When it's next asked.
    public var due: Date
    public var createdAt: Date
    public var reviewedAt: Date?
    /// How many times it's been answered.
    public var reviewCount: Int
    /// How many of those times the student didn't know it.
    public var missCount: Int

    public init(
        id: UUID = UUID(),
        subjectID: Subject.ID,
        question: String,
        answer: String,
        sourceID: UUID? = nil,
        sourceName: String? = nil,
        quote: String? = nil,
        assessmentID: Assessment.ID? = nil,
        origin: Origin = .student,
        box: Int = 1,
        due: Date = .now,
        createdAt: Date = .now,
        reviewedAt: Date? = nil,
        reviewCount: Int = 0,
        missCount: Int = 0
    ) {
        self.id = id
        self.subjectID = subjectID
        self.question = question
        self.answer = answer
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.quote = quote
        self.assessmentID = assessmentID
        self.origin = origin
        self.box = box
        self.due = due
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
        self.reviewCount = reviewCount
        self.missCount = missCount
    }

    public static let boxCount = 5

    /// Days until a card in each box is asked again: the next day for box 1,
    /// then 3, 7, 14 and 30 days.
    public static let daysUntilAskedAgain = [1, 3, 7, 14, 30]

    public func isDue(at now: Date) -> Bool {
        due <= now
    }

    /// Asked rarely now: the student has known it several times running.
    public var isLearnt: Bool {
        box >= 4
    }

    /// The card after the student answered it: up a box if they knew it, back
    /// to the first box if they didn't. It's next asked at the start of a day,
    /// so it's waiting first thing rather than at the time it was last answered.
    public func answered(knewIt: Bool, at now: Date, calendar: Calendar) -> Flashcard {
        var card = self
        card.box = knewIt ? min(max(box, 1) + 1, Self.boxCount) : 1
        card.reviewCount += 1
        if !knewIt { card.missCount += 1 }
        card.reviewedAt = now
        let days = Self.daysUntilAskedAgain[card.box - 1]
        card.due = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(Double(days) * 86_400)
        return card
    }

    /// The cards to ask now, most overdue first, and among those the ones the
    /// student knows least.
    public static func dueCards(_ cards: [Flashcard], at now: Date, limit: Int? = nil) -> [Flashcard] {
        let due = cards.filter { $0.isDue(at: now) }.sorted { ($0.due, $0.box) < ($1.due, $1.box) }
        return limit.map { Array(due.prefix($0)) } ?? due
    }
}

/// A past paper the student practised: how long it took and the mark they gave themselves.
public struct PracticeAttempt: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var subjectID: Subject.ID
    /// The paper's file name, which pairs the attempt with the paper.
    public var paperName: String
    /// The paper's filed record, when Folio filed it.
    public var paperID: UUID?
    public var date: Date
    public var minutes: Int
    public var mark: Assessment.Mark?
    public var note: String

    public init(id: UUID = UUID(), subjectID: Subject.ID, paperName: String, paperID: UUID? = nil, date: Date = .now, minutes: Int, mark: Assessment.Mark? = nil, note: String = "") {
        self.id = id
        self.subjectID = subjectID
        self.paperName = paperName
        self.paperID = paperID
        self.date = date
        self.minutes = minutes
        self.mark = mark
        self.note = note
    }
}
