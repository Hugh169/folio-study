import Foundation

/// Applies the student's own rules. The first matching rule wins.
public struct RuleVoter: Voter {
    public let kind = VoterKind.rules

    public init() {}

    public func vote(on evidence: Evidence, profile: Profile) async -> Vote {
        for rule in profile.rules {
            guard let subject = profile.subject(rule.subjectID), !subject.isArchived else { continue }
            let values: [String] = switch rule.field {
            case .fileName: [evidence.fileName]
            case .sourceURL: evidence.sourceURLs
            case .sourceFolder: [evidence.folderName ?? ""]
            }
            if values.contains(where: { $0.localizedCaseInsensitiveContains(rule.contains) }) {
                return Vote(
                    voter: .rules,
                    scores: [subject.id: 1],
                    strength: 1,
                    facets: Facets(documentType: rule.documentType),
                    reasons: [String(localized: "Your rule: “\(rule.contains)” goes to \(subject.name)", bundle: .module)]
                )
            }
        }
        return .abstained(.rules, .noEvidence, String(localized: "No rule matched", bundle: .module))
    }
}
