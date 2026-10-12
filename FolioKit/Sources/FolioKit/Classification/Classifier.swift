import Foundation

/// Runs the voters on a file and lets the arbiter decide.
public struct Classifier: Sendable {
    public var voters: [any Voter]

    public init(voters: [any Voter]) {
        self.voters = voters
    }

    /// Rules, keywords, then, when given, the timetable, similar past files and the on-device AI.
    public static func standard(model: ModelVoter? = ModelVoter(), examples: ExampleVoter? = nil, timetable: TimetableVoter? = nil) -> Classifier {
        var voters: [any Voter] = [RuleVoter(), KeywordVoter()]
        if let timetable { voters.append(timetable) }
        if let examples { voters.append(examples) }
        if let model { voters.append(model) }
        return Classifier(voters: voters)
    }

    /// Every voter's opinion. `willAsk` hears each voter's kind just before it
    /// votes, so the slower ones can be shown as progress.
    public func votes(for evidence: Evidence, profile: Profile, willAsk: (@Sendable (VoterKind) -> Void)? = nil) async -> [Vote] {
        var votes: [Vote] = []
        for voter in voters {
            willAsk?(voter.kind)
            let vote = await voter.vote(on: evidence, profile: profile)
            votes.append(vote)
            // The student's own rule settles it, so skip the slower voters.
            if vote.voter == .rules && vote.abstention == nil { break }
        }
        return votes
    }

    public func classify(_ evidence: Evidence, profile: Profile) async -> Decision {
        Arbiter(level: profile.autoFileLevel).decide(await votes(for: evidence, profile: profile), evidence: evidence, profile: profile)
    }

    /// The votes once Claude has answered about a file the others left for
    /// review. Claude's vote takes the place of the on-device AI's, and the
    /// arbiter's rules stay the same, so Claude can only help file something
    /// when the words in the file agree. When Claude didn't answer, its
    /// abstention is added and nothing else changes.
    public static func votes(_ votes: [Vote], adding secondOpinion: Vote) -> [Vote] {
        guard secondOpinion.abstention == nil else { return votes + [secondOpinion] }
        return votes.filter { $0.voter != .model } + [secondOpinion]
    }
}
