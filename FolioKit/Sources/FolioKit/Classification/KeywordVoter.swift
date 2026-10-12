import Foundation

/// Looks for each subject's name, aliases, course codes and topic words. Fast,
/// works in any language the student adds words for, and is never refused.
public struct KeywordVoter: Voter {
    public let kind = VoterKind.keywords

    /// Weight of a subject's name, alias or code compared with a topic word.
    var nameWeight = 3.0
    /// A term counts at most this many times in each part of the file.
    var maxHitsPerTerm = 3
    /// Keeps a few weak hits from looking like certainty.
    var smoothing = 3.0
    /// Weight of a file written in the language a language course studies,
    /// when the student is taught in another, about the same as finding the
    /// course's name in the file name.
    var languageWeight = 6.0
    /// Shorter files are too unreliable for telling their language.
    var minimumTextForLanguage = 80

    public init() {}

    public func vote(on evidence: Evidence, profile: Profile) async -> Vote {
        let parts = Self.parts(of: evidence)
        let subjects = profile.sortableSubjects
        let termLists = subjects.map(terms(for:))
        var scores: [Subject.ID: Double] = [:]
        var found: [Subject.ID: [String]] = [:]
        var writtenIn: [Subject.ID: String] = [:]

        var matchedTerms = Set<TermKey>()
        for part in parts {
            var hits: [TermKey: Int] = [:]
            for match in matches(in: part, termLists: termLists) {
                hits[match.key, default: 0] += 1
            }
            for (key, count) in hits {
                let term = termLists[key.subject][key.term]
                scores[subjects[key.subject].id, default: 0] += term.weight * part.weight * Double(min(count, maxHitsPerTerm))
                matchedTerms.insert(key)
            }
        }
        for (subjectIndex, subject) in subjects.enumerated() {
            let terms = termLists[subjectIndex]
            for termIndex in terms.indices where matchedTerms.contains(TermKey(subject: subjectIndex, term: termIndex)) {
                found[subject.id, default: []].append(terms[termIndex].text)
            }
            if let language = subject.languageOfStudy, isWritten(in: language, evidence: evidence, profile: profile) {
                scores[subject.id, default: 0] += languageWeight
                writtenIn[subject.id] = language
            }
        }

        guard let best = scores.max(by: { $0.value < $1.value }) else {
            return .abstained(.keywords, .noEvidence, String(localized: "No subject words found", bundle: .module))
        }
        let total = scores.values.reduce(0, +)
        var reasons: [String] = []
        if let language = writtenIn[best.key] {
            reasons.append(String(localized: "Written in \(Locale.current.localizedString(forLanguageCode: language) ?? language)", bundle: .module, comment: "The language a file is written in, such as “Written in French”"))
        }
        if let terms = found[best.key], !terms.isEmpty {
            reasons.append(String(localized: "Found \(terms.prefix(3).map { "“\($0)”" }.joined(separator: ", "))", bundle: .module, comment: "Words found in a file, such as Found “titration”, “burette”"))
        }
        return Vote(
            voter: .keywords,
            scores: scores.mapValues { $0 / (total + smoothing) },
            strength: best.value,
            reasons: reasons
        )
    }

    private struct Term {
        var text: String
        var weight: Double
        /// For codes ending in "*": how many more letters or digits may follow.
        var extraCharacters = 0
        /// A name in capitals such as "IT", found only in capitals.
        var isAbbreviation = false
        var normalized: String

        init(text: String, weight: Double, extraCharacters: Int = 0, isAbbreviation: Bool = false) {
            self.text = text
            self.weight = weight
            self.extraCharacters = extraCharacters
            self.isAbbreviation = isAbbreviation
            self.normalized = TermMatcher.normalize(text)
        }
    }

    /// A subject's term, by their positions in the profile and term list.
    private struct TermKey: Hashable {
        var subject: Int
        var term: Int
    }

    /// Where a subject's term was found in one part of a file. Abbreviations
    /// have no range: they're matched in the original text, and never overlap
    /// another subject's words.
    private struct Match {
        var key: TermKey
        var range: Range<String.Index>?
    }

    /// Every term found in one part of a file. The longest match wins: when
    /// "Hess's law" counts for Chemistry, the "law" inside it doesn't count
    /// for a subject called Law.
    private func matches(in part: Part, termLists: [[Term]]) -> [Match] {
        var matches: [Match] = []
        for (subjectIndex, terms) in termLists.enumerated() {
            for (termIndex, term) in terms.enumerated() {
                let key = TermKey(subject: subjectIndex, term: termIndex)
                if term.isAbbreviation {
                    let count = TermMatcher.count(ofAbbreviation: term.text, in: part.original, ignoringCapitalisedRuns: part.isBody)
                    matches += Array(repeating: Match(key: key, range: nil), count: count)
                } else {
                    matches += TermMatcher.ranges(of: term.normalized, in: part.text, extraCharacters: term.extraCharacters)
                        .map { Match(key: key, range: $0) }
                }
            }
        }
        return matches.filter { match in
            guard let range = match.range else { return true }
            return !matches.contains { other in
                guard other.key.subject != match.key.subject, let outer = other.range, outer != range else { return false }
                return outer.lowerBound <= range.lowerBound && range.upperBound <= outer.upperBound
            }
        }
    }

    /// Names, aliases and codes first, so they lead the reasons.
    private func terms(for subject: Subject) -> [Term] {
        let names = ([subject.name] + subject.aliases).map { Term(text: $0, weight: nameWeight, isAbbreviation: TermMatcher.isAbbreviation($0)) }
        let codes = subject.codes.map { code in
            code.hasSuffix("*") ? Term(text: String(code.dropLast()), weight: nameWeight, extraCharacters: 3) : Term(text: code, weight: nameWeight)
        }
        return names + codes + subject.keywords.map { Term(text: $0, weight: 1) }
    }

    /// A long enough file written in `language`, when the student is taught in another.
    private func isWritten(in language: String, evidence: Evidence, profile: Profile) -> Bool {
        guard evidence.text.count >= minimumTextForLanguage,
              let detected = evidence.language.flatMap({ Locale.Language(identifier: $0).languageCode?.identifier }),
              let studied = Locale.Language(identifier: language).languageCode?.identifier
        else { return false }
        let taught = Locale.Language(identifier: profile.language ?? "en").languageCode?.identifier
        return detected == studied && taught != studied
    }

    /// A part of a file that's searched: normalised for matching words, and
    /// as written for matching abbreviations in capitals.
    struct Part {
        var text: String
        var original: String
        var weight: Double
        /// The file's text, rather than its name or title.
        var isBody: Bool

        init(_ original: String, weight: Double, isBody: Bool) {
            self.text = TermMatcher.normalize(original)
            self.original = original
            self.weight = weight
            self.isBody = isBody
        }
    }

    /// The parts of a file that are searched, and how much each counts. The file
    /// name and title count double; the first lines count more than the rest.
    /// The folder a file came from is deliberately left out.
    static func parts(of evidence: Evidence) -> [Part] {
        [
            Part(evidence.readableFileName, weight: 2, isBody: false),
            Part(evidence.title ?? "", weight: 2, isBody: false),
            Part(String(evidence.text.prefix(400)), weight: 1.5, isBody: true),
            Part(String(evidence.text.dropFirst(400)), weight: 1, isBody: true),
        ]
    }
}
