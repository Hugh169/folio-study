import Foundation

/// A class in the student's timetable, matched to one of their subjects.
public struct ClassSession: Hashable, Sendable {
    public var subjectID: Subject.ID
    /// The event's title, such as "COMP1511 Lecture".
    public var title: String
    public var start: Date
    public var end: Date

    public init(subjectID: Subject.ID, title: String, start: Date, end: Date) {
        self.subjectID = subjectID
        self.title = title
        self.start = start
        self.end = end
    }
}

/// Votes for the subject whose class was on when a file arrived: slides
/// downloaded during a COMP1511 lecture are probably COMP1511. It's a separate
/// signal from what's in the file, and stays out when two classes overlap.
public actor TimetableVoter: Voter {
    public nonisolated let kind = VoterKind.timetable

    /// A file counts from this long before a class starts…
    static let before: TimeInterval = 15 * 60
    /// …until this long after it ends.
    static let after: TimeInterval = 30 * 60

    private var classes: [ClassSession]

    public init(classes: [ClassSession] = []) {
        self.classes = classes
    }

    public func update(_ classes: [ClassSession]) {
        self.classes = classes
    }

    public func vote(on evidence: Evidence, profile: Profile) async -> Vote {
        guard !classes.isEmpty else {
            return .abstained(.timetable, .noEvidence, String(localized: "No timetable", bundle: .module))
        }
        guard let arrived = evidence.arrived else {
            return .abstained(.timetable, .noEvidence, String(localized: "Couldn't tell when it arrived", bundle: .module))
        }
        let current = Set(profile.sortableSubjects.map(\.id))
        let during = classes.filter {
            current.contains($0.subjectID) && arrived >= $0.start.addingTimeInterval(-Self.before) && arrived <= $0.end.addingTimeInterval(Self.after)
        }
        guard let first = during.first else {
            return .abstained(.timetable, .noEvidence, String(localized: "Didn't arrive during a class", bundle: .module))
        }
        guard Set(during.map(\.subjectID)).count == 1, let subject = profile.subject(first.subjectID) else {
            return .abstained(.timetable, .noEvidence, String(localized: "Arrived while two classes were on", bundle: .module))
        }
        return Vote(voter: .timetable, scores: [subject.id: 1], strength: 1, reasons: [String(localized: "Arrived during \(first.title)", bundle: .module, comment: "The class a file arrived in, such as “Arrived during Physics, Period 3”")])
    }
}
