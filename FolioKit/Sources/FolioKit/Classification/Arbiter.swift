import Foundation

/// What Folio decided to do with a file, and why.
public struct Decision: Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Confident enough to file it without asking.
        case file(Subject.ID)
        /// Ask the student, offering `suggestions`.
        case review
        /// Doesn't look like schoolwork, so leave it where it is.
        case notSchoolwork
    }

    public var outcome: Outcome
    /// Subjects in order of combined support, strongest first.
    public var ranking: [Subject.ID]
    /// Up to two subjects to offer when asking the student.
    public var suggestions: [Subject.ID]
    public var facets: Facets
    /// Readable reasons for the "why" line.
    public var reasons: [String]
    public var votes: [Vote]
}

/// Combines the votes. Confidence comes from separate signals agreeing, never
/// from the model's own sense of certainty, which can't be trusted.
public struct Arbiter: Sendable {
    public var level: AutoFileLevel

    /// How much each voter's backing counts towards a subject.
    var weights: [VoterKind: Double] = [.rules: 3, .keywords: 1, .examples: 1, .model: 1, .timetable: 1, .cloud: 1]
    /// Keyword evidence at least this strong, and this one-sided, can file on its own at Balanced.
    var strongKeywordStrength = 9.0
    var strongKeywordShare = 0.7

    public init(level: AutoFileLevel) {
        self.level = level
    }

    public func decide(_ votes: [Vote], evidence: Evidence, profile: Profile) -> Decision {
        let active = votes.filter { $0.abstention == nil }
        let facets = mergedFacets(votes, evidence: evidence, profile: profile)

        // The student's own rule wins outright.
        if let rule = active.first(where: { $0.voter == .rules }), let id = rule.top?.id {
            return Decision(outcome: .file(id), ranking: [id], suggestions: [id], facets: facets, reasons: rule.reasons, votes: votes)
        }

        var combined: [Subject.ID: Double] = [:]
        for vote in active {
            for (id, score) in vote.scores {
                combined[id, default: 0] += (weights[vote.voter] ?? 1) * score
            }
        }
        let ranking = combined.sorted { $0.value > $1.value }.map(\.key)
        let abstentionReasons = votes.compactMap { $0.abstention?.kind == .declined ? $0.abstention?.reason : nil }

        guard let winner = ranking.first else {
            let saysNotSchoolwork = active.contains { $0.notSchoolwork >= 0.5 }
            return Decision(
                outcome: saysNotSchoolwork ? .notSchoolwork : .review,
                ranking: [],
                suggestions: [],
                facets: facets,
                reasons: saysNotSchoolwork ? active.flatMap(\.reasons) : [String(localized: "Couldn't find anything that points to a subject", bundle: .module)] + abstentionReasons,
                votes: votes
            )
        }

        let supporters = active.filter { $0.top?.id == winner }
        let dissenters = active.filter { vote in
            if let top = vote.top?.id { return top != winner }
            return vote.notSchoolwork >= 0.5
        }
        let keywords = active.first { $0.voter == .keywords }
        let strongKeywords = keywords.map {
            $0.top?.id == winner && $0.strength >= strongKeywordStrength && ($0.scores[winner] ?? 0) >= strongKeywordShare
        } ?? false

        // Agreement only counts when the words in the file are part of it. The AI
        // and the similar-files voter can both be fooled by a file with no subject
        // words: in testing both called a guitar chord chart Mathematics.
        let agreement = supporters.count >= 2 && supporters.contains { $0.voter == .keywords }
        let fileIt = switch level {
        case .careful: agreement && dissenters.isEmpty
        case .balanced: dissenters.isEmpty && (agreement || strongKeywords)
        case .eager: dissenters.isEmpty || (strongKeywords && supporters.count > dissenters.count)
        }

        var suggestions = Array(ranking.prefix(2))
        if suggestions.count < 2, let aiPick = active.first(where: { $0.voter == .model || $0.voter == .cloud })?.top?.id, !suggestions.contains(aiPick) {
            suggestions.append(aiPick)
        }
        let reasons = supporters.flatMap(\.reasons) + dissenters.flatMap(\.reasons) + abstentionReasons

        return Decision(
            outcome: fileIt ? .file(winner) : .review,
            ranking: ranking,
            suggestions: suggestions,
            facets: facets,
            reasons: reasons,
            votes: votes
        )
    }

    /// A rule's document type first, then words in the file, then the AI's
    /// answer, then the student's default. In testing, words in the file were
    /// rarely wrong when they found a type, while the AI often guessed.
    private func mergedFacets(_ votes: [Vote], evidence: Evidence, profile: Profile) -> Facets {
        let found = FacetHeuristics.facets(for: evidence, profile: profile)
        // Claude's answer, when it was asked, or the on-device AI's.
        let model = votes.last { ($0.voter == .model || $0.voter == .cloud) && $0.abstention == nil }?.facets
        let rule = votes.first { $0.voter == .rules && $0.abstention == nil }?.facets
        let documentType = rule?.documentType ?? found.documentType ?? model?.documentType ?? profile.defaultDocumentType
        // The AI sometimes gives a historical date as the year, so only trust it for exam papers.
        let modelYear = FacetHeuristics.looksLikeExam(type: documentType, exam: found.exam) ? model?.year : nil
        return Facets(documentType: documentType, year: found.year ?? modelYear, exam: found.exam)
    }
}
