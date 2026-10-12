import Foundation
import UniformTypeIdentifiers

/// Simple rules for a file's document type, year and exam, used when the
/// on-device AI didn't provide them.
enum FacetHeuristics {
    static func facets(for evidence: Evidence, profile: Profile) -> Facets {
        let exam = exam(in: evidence, profile: profile)
        let type = documentType(in: evidence, profile: profile)
        return Facets(documentType: type, year: year(in: evidence, looksLikeExam: looksLikeExam(type: type, exam: exam)), exam: exam)
    }

    /// Whether a year near the top of the file is the paper's year. In notes and
    /// essays, years are usually historical dates, such as 1941 in Holocaust notes.
    static func looksLikeExam(type: String?, exam: String?) -> Bool {
        exam != nil || type.map(examTypes.contains) == true
    }

    /// Kinds of document that hold exam papers, across the curriculum packs.
    static let examTypes: Set<String> = ["Past Papers", "Mark Schemes", "Markschemes", "Practice Exams"]

    /// A type that claims this kind of file, such as Recordings for audio;
    /// otherwise the type whose words appear most, counting the file name and title double.
    static func documentType(in evidence: Evidence, profile: Profile) -> String? {
        if let kind = UTType(evidence.contentType),
           let type = profile.documentTypes.first(where: { type in
               type.fileKinds.contains { UTType($0).map(kind.conforms(to:)) ?? false }
           }) {
            return type.name
        }
        if let role = examPaperRole(of: evidence),
           let type = profile.documentTypes.first(where: { type in ([type.name] + type.aliases).contains { TermMatcher.normalize($0) == role } }) {
            return type.name
        }
        let parts = searchableParts(of: evidence)
        let scored = profile.documentTypes.map { type -> (String, Double) in
            let terms = ([type.name] + type.aliases).map(TermMatcher.normalize)
            let score = parts.reduce(0.0) { total, part in
                total + terms.reduce(0.0) { $0 + (TermMatcher.contains($1, in: part.text) ? part.weight : 0) }
            }
            return (type.name, score)
        }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// Exam boards name their files with short codes, such as Cambridge's
    /// "0580_s23_qp_42" and AQA's "AQA-84611H-MS-JUN22". The codes are too risky
    /// to look for in text ("ms" is also "Ms Smith"), so they only count in a file
    /// name that has an exam code too. Returns "question paper", "mark scheme"
    /// or "examiner report", which match the kinds of document's words.
    static func examPaperRole(of evidence: Evidence) -> String? {
        let tokens = TermMatcher.normalize(evidence.readableFileName).split(separator: " ").map(String.init)
        // Cambridge: a series such as s23 (summer 2023), with the paper's code.
        let isCambridge = tokens.contains { $0.wholeMatch(of: /[smwy]\d{2}/) != nil } && tokens.contains { $0.wholeMatch(of: /\d{4}/) != nil }
        let hasExamCode = isCambridge || tokens.contains { token in
            token.wholeMatch(of: /\d{4}[a-z0-9]{0,3}/) != nil       // AQA: 8461, 84611h
                || token.wholeMatch(of: /\d[a-z]{2}\d/) != nil      // Edexcel: 1ma1
                || token.wholeMatch(of: /[a-z]\d{3}/) != nil         // OCR: j560, h240
                || ["aqa", "ocr", "edexcel", "eduqas", "wjec"].contains(token)
        }
        guard hasExamCode else { return nil }
        let markScheme: Set<String> = ["ms", "rms", "markscheme"]
        let report: Set<String> = isCambridge ? ["er", "gt"] : ["pef", "wre", "er"]
        let paper: Set<String> = isCambridge ? ["qp", "in", "pm", "sf", "ci", "ir"] : ["qp", "que", "ins"]
        if tokens.contains(where: markScheme.contains) { return "mark scheme" }
        if tokens.contains(where: report.contains) { return "examiner report" }
        if tokens.contains(where: paper.contains) { return "question paper" }
        return nil
    }

    /// A year from 1990 to next year in the file name or title, or in the first
    /// lines when the file looks like an exam paper.
    static func year(in evidence: Evidence, looksLikeExam: Bool) -> Int? {
        let latest = Calendar(identifier: .gregorian).component(.year, from: .now) + 1
        let places = [evidence.readableFileName, evidence.title ?? ""] + (looksLikeExam ? [String(evidence.text.prefix(400))] : [])
        for text in places {
            for match in text.matches(of: /\b(?:19|20)\d{2}\b/) {
                if let year = Int(text[match.range]), (1990...latest).contains(year) {
                    return year
                }
            }
        }
        return nil
    }

    /// The first exam or board named in the file name, title or first lines.
    static func exam(in evidence: Evidence, profile: Profile) -> String? {
        let text = searchableParts(of: evidence).map(\.text).joined(separator: "\n")
        return profile.examBoards.first { board in
            ([board.name] + board.aliases).contains { TermMatcher.contains(TermMatcher.normalize($0), in: text) }
        }?.name
    }

    private static func searchableParts(of evidence: Evidence) -> [(text: String, weight: Double)] {
        [
            (TermMatcher.normalize(evidence.readableFileName), 2),
            (TermMatcher.normalize(evidence.title ?? ""), 2),
            (TermMatcher.normalize(String(evidence.text.prefix(400))), 1),
        ]
    }
}
