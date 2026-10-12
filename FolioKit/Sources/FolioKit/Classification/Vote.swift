import Foundation

/// The separate signals Folio weighs when choosing a subject.
public enum VoterKind: String, Codable, Sendable, CaseIterable {
    /// The student's own rules.
    case rules
    /// Subject names, aliases, course codes and topic words found in the file.
    case keywords
    /// Similarity to files the student has already filed.
    case examples
    /// Apple's on-device language model.
    case model
    /// The student's timetable: a file that arrived during a class.
    case timetable
    /// Claude, with the student's own API key, for files the rest can't decide.
    case cloud
}

/// Details worked out about a file besides its subject.
public struct Facets: Hashable, Codable, Sendable {
    public var documentType: String?
    public var year: Int?
    public var exam: String?

    public init(documentType: String? = nil, year: Int? = nil, exam: String? = nil) {
        self.documentType = documentType
        self.year = year
        self.exam = exam
    }
}

/// Why a voter didn't vote.
public struct Abstention: Hashable, Sendable {
    public enum Kind: Sendable {
        /// Nothing in the file pointed anywhere.
        case noEvidence
        /// The AI refused to answer, usually a safety filter on sensitive topics.
        case declined
        /// The AI isn't available on this Mac right now.
        case unavailable
        /// Something went wrong.
        case failed
    }

    public var kind: Kind
    public var reason: String
    /// The underlying error, for reports and debugging. Not shown to students.
    public var detail: String?

    public init(kind: Kind, reason: String, detail: String? = nil) {
        self.kind = kind
        self.reason = reason
        self.detail = detail
    }
}

/// One voter's opinion about a file.
public struct Vote: Sendable {
    public var voter: VoterKind
    /// How strongly this voter backs each subject, 0 to 1. Empty when it abstained.
    public var scores: [Subject.ID: Double]
    /// How strongly this voter thinks the file isn't schoolwork, 0 to 1.
    public var notSchoolwork: Double
    /// Raw weight of evidence for the top subject, on the voter's own scale.
    public var strength: Double
    public var facets: Facets
    /// Short, readable reasons, such as "Found “Modern History”".
    public var reasons: [String]
    public var abstention: Abstention?

    public init(
        voter: VoterKind,
        scores: [Subject.ID: Double],
        notSchoolwork: Double = 0,
        strength: Double = 0,
        facets: Facets = Facets(),
        reasons: [String] = [],
        abstention: Abstention? = nil
    ) {
        self.voter = voter
        self.scores = scores
        self.notSchoolwork = notSchoolwork
        self.strength = strength
        self.facets = facets
        self.reasons = reasons
        self.abstention = abstention
    }

    public static func abstained(_ voter: VoterKind, _ kind: Abstention.Kind, _ reason: String, detail: String? = nil) -> Vote {
        Vote(voter: voter, scores: [:], abstention: Abstention(kind: kind, reason: reason, detail: detail))
    }

    /// The subject this voter backs most, if any.
    public var top: (id: Subject.ID, score: Double)? {
        scores.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

public protocol Voter: Sendable {
    var kind: VoterKind { get }
    func vote(on evidence: Evidence, profile: Profile) async -> Vote
}
