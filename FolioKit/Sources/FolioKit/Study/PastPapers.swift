import Foundation

/// A subject's past papers, each paired with its marking guidelines when the
/// student has them, newest first, for practising.
public enum PastPapers {
    /// A file that might be a paper or its guidelines.
    public struct File: Hashable, Sendable {
        public var name: String
        public var url: URL?
        public var year: Int?
        public var exam: String?

        public init(name: String, url: URL? = nil, year: Int? = nil, exam: String? = nil) {
            self.name = name
            self.url = url
            self.year = year
            self.exam = exam
        }
    }

    public struct Paper: Identifiable, Hashable, Sendable {
        public var id: String { file.url?.path(percentEncoded: false) ?? file.name }
        public var file: File
        /// Marking guidelines, mark schemes or sample answers for it.
        public var guidelines: [File]
        public var year: Int?
        /// Such as "HSC" or "Trial".
        public var exam: String?
        /// Such as "1" for Paper 1, or "42" for Cambridge's paper 4, variant 2.
        public var number: String?
        /// Guidelines Folio couldn't match to a paper the student has.
        public var isGuidelinesOnly: Bool = false

        /// "2023 HSC", "2019 Trial · Paper 1", or the file's name without its extension.
        public var title: String {
            let paper = number.map { String(localized: "Paper \($0)", bundle: .module) }
            let parts = [[year.map(String.init), exam].compactMap { $0 }.joined(separator: " "), paper].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? (file.name as NSString).deletingPathExtension : parts.joined(separator: " · ")
        }
    }

    /// Words in a kind of document's name or aliases that mean it holds exam papers or their marking.
    private static let paperWords = ["past paper", "exam paper", "past exam", "practice exam", "sample exam", "mark scheme", "markscheme", "marking guidelines", "scoring guidelines"]

    /// Whether a kind of document holds exam papers or their marking
    /// guidelines, such as "Past Papers", "Mark Schemes" or "Practice Exams":
    /// its name says so, or one of its other names is exactly "past exam" and
    /// the like. ("Topical past papers" doesn't make Revision a kind of paper.)
    public static func holdsPapers(_ type: DocumentType) -> Bool {
        let name = TermMatcher.normalize(type.name)
        return paperWords.contains { name.contains($0) }
            || type.aliases.contains { paperWords.contains(TermMatcher.normalize($0)) }
    }

    /// Words in a file name that mean it's the marking, not the paper.
    private static let guidelinePhrases = [
        "marking guideline", "marking guide", "marking criteria", "marking scheme", "mark scheme", "markscheme",
        "scoring guideline", "sample answer", "suggested answer", "worked solution", "solutions", "answers", "answer key",
        "examiner report", "examiners report", "notes from the marking centre", "marking feedback",
    ]
    /// Short forms in names: NESA's "-mg", Cambridge's "_ms_" and "_er_".
    private static let guidelineTokens: Set<String> = ["mg", "ms", "er", "msc", "sol", "solns", "ans"]

    /// Whether a file is marking guidelines rather than the paper, from its name.
    public static func isGuidelines(_ name: String) -> Bool {
        let words = tokens(name)
        let joined = words.joined(separator: " ")
        return guidelinePhrases.contains { joined.contains($0) } || words.contains(where: guidelineTokens.contains)
    }

    /// The year in a name, such as 2023 in "2023-hsc-physics" or Cambridge's "s23".
    public static func year(in name: String) -> Int? {
        let words = tokens(name)
        for word in words {
            if let match = word.wholeMatch(of: /(19|20)\d{2}/), let year = Int(match.0) { return year }
        }
        for word in words {
            if let match = word.wholeMatch(of: /[smw](\d{2})/), let short = Int(match.1) { return 2000 + short }
        }
        return nil
    }

    /// The paper's number: "1" for "Paper 1" or "P1", "42" for Cambridge's "qp_42".
    static func number(in name: String) -> String? {
        let words = tokens(name)
        for (index, word) in words.enumerated() {
            if word == "paper" || word == "qp" || word == "ms", index + 1 < words.count, words[index + 1].allSatisfy(\.isNumber), words[index + 1].count <= 2 {
                return words[index + 1]
            }
            if let match = word.wholeMatch(of: /(?:paper|p)(\d{1,2})/) { return String(match.1) }
        }
        return nil
    }

    /// "Trial" or "Mock" from the name, for schools' own exams.
    static func exam(in name: String) -> String? {
        let words = Set(tokens(name))
        if words.contains("trial") { return String(localized: "Trial", bundle: .module) }
        if words.contains("mock") { return String(localized: "Mock", bundle: .module) }
        return nil
    }

    /// A paper's working and reading time in minutes, from its instructions,
    /// such as "Reading time – 10 minutes • Working time – 3 hours" or "Time
    /// allowed: 1 hour 30 minutes". With no label, the first length in its
    /// opening lines is taken as the working time, as IB and Cambridge papers give it.
    public static func times(in text: String) -> (working: Int?, reading: Int?) {
        let lower = TermMatcher.normalize(text)
        func length(after labels: [String]) -> Int? {
            for label in labels {
                guard let range = lower.range(of: label) else { continue }
                if let minutes = duration(in: String(lower[range.upperBound...].prefix(40))) { return minutes }
            }
            return nil
        }
        let reading = length(after: ["reading time", "reading and planning time"])
        var working = length(after: ["working time", "writing time", "time allowed", "duration", "duree de l'epreuve", "duracion"])
        if working == nil {
            let opening = String(lower.prefix(400))
            // Leave out the reading time's own words so they aren't taken for the working time.
            let unlabelled = lower.range(of: "reading time").map { opening.replacingCharacters(in: $0.lowerBound..<min($0.upperBound, opening.endIndex), with: "") } ?? opening
            working = duration(in: unlabelled)
        }
        return (working, reading)
    }

    /// The first length in the text, such as "3 hours", "1 hour 30 minutes",
    /// "2 h 15", "90 minutes" or "4 heures", in minutes.
    static func duration(in text: String) -> Int? {
        let pattern = /(\d{1,2}(?:[.,]5)?)\s*(?:hours?|hrs?|h|heures?|horas?)\b(?:\s*(?:and\s*)?(\d{1,2})\s*(?:minutes?|mins?)?)?|(\d{1,3})\s*(?:minutes?|mins?)\b/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        if let hours = match.1.flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }) {
            return Int(hours * 60) + (match.2.flatMap { Int($0) } ?? 0)
        }
        return match.3.flatMap { Int($0) }
    }

    /// Pairs each paper with its guidelines, newest first.
    public static func papers(from files: [File]) -> [Paper] {
        let describe = { (file: File) in
            Paper(
                file: file,
                guidelines: [],
                year: file.year ?? year(in: file.name),
                exam: exam(in: file.name) ?? file.exam,
                number: number(in: file.name)
            )
        }
        var papers = files.filter { !isGuidelines($0.name) }.map(describe)
        var unmatched: [Paper] = []
        for guide in files.filter({ isGuidelines($0.name) }) {
            let wanted = describe(guide)
            let words = Set(tokens(guide.name)).subtracting(guidelineTokens)
            let candidates = papers.indices.filter { index in
                let paper = papers[index]
                return agree(paper.year, wanted.year) && agree(paper.number, wanted.number) && agree(paper.exam?.lowercased(), wanted.exam?.lowercased())
                    && (paper.year != nil || wanted.year == nil)
            }
            let best = candidates.max { a, b in
                overlap(words, Set(tokens(papers[a].file.name))) < overlap(words, Set(tokens(papers[b].file.name)))
            }
            if let best, wanted.year != nil || overlap(words, Set(tokens(papers[best].file.name))) >= 0.5 {
                papers[best].guidelines.append(guide)
            } else {
                var alone = wanted
                alone.isGuidelinesOnly = true
                unmatched.append(alone)
            }
        }
        return (papers + unmatched).sorted { a, b in
            if a.year != b.year { return (a.year ?? 0) > (b.year ?? 0) }
            if a.exam != b.exam { return (a.exam ?? "") < (b.exam ?? "") }
            if a.number != b.number { return (a.number ?? "") < (b.number ?? "") }
            return a.file.name.localizedStandardCompare(b.file.name) == .orderedAscending
        }
    }

    /// Both unknown, one unknown, or the same.
    private static func agree<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
        a == nil || b == nil || a == b
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// A name's words in lower case, split at spaces, dashes, underscores and
    /// dots, with the file extension left out.
    static func tokens(_ name: String) -> [String] {
        let stem = (name as NSString).deletingPathExtension
        return TermMatcher.normalize(stem)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
