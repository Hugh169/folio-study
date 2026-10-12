import Foundation
import FolioKit

/// One file's evaluation.
struct Result {
    let path: String
    /// The correct subject's name, or nil when the file shouldn't be filed.
    let expected: String?
    let tags: [String]
    let expectedType: String?
    let evidence: Evidence
    let extractionFailed: Bool
    let votes: [Vote]
    let decisions: [AutoFileLevel: Decision]
    let extractionSeconds: Double
    let classificationSeconds: Double
    let profile: Profile

    var isSchoolwork: Bool { expected != nil }

    /// The same file decided without one voter, to measure what it adds.
    func without(_ kind: VoterKind) -> Result {
        let remaining = votes.filter { $0.voter != kind }
        return Result(
            path: path,
            expected: expected,
            tags: tags,
            expectedType: expectedType,
            evidence: evidence,
            extractionFailed: extractionFailed,
            votes: remaining,
            decisions: Dictionary(uniqueKeysWithValues: AutoFileLevel.allCases.map {
                ($0, Arbiter(level: $0).decide(remaining, evidence: evidence, profile: profile))
            }),
            extractionSeconds: extractionSeconds,
            classificationSeconds: classificationSeconds,
            profile: profile
        )
    }

    func name(_ id: Subject.ID?) -> String? {
        id.flatMap { profile.subject($0)?.name }
    }

    func vote(_ kind: VoterKind) -> Vote? {
        votes.first { $0.voter == kind }
    }

    /// The subject with the most combined support, whatever the outcome.
    var topChoice: String? {
        name(decisions[.balanced]?.ranking.first)
    }

    func filed(_ level: AutoFileLevel) -> String? {
        if case .file(let id) = decisions[level]?.outcome { return name(id) }
        return nil
    }

    /// Filed somewhere it shouldn't be: the worst mistake Folio can make.
    func wronglyFiled(_ level: AutoFileLevel) -> Bool {
        guard let filed = filed(level) else { return false }
        return filed != expected
    }

    /// Asked, and the right subject was one of the offered choices.
    func reviewOffersCorrectSubject(_ level: AutoFileLevel) -> Bool {
        guard let decision = decisions[level], decision.outcome == .review, let expected else { return false }
        return decision.suggestions.compactMap(name).contains(expected)
    }

    func describe(_ level: AutoFileLevel) -> String {
        guard let decision = decisions[level] else { return "?" }
        let verdict: String = switch decision.outcome {
        case .file(let id): "filed: \(name(id) ?? "?")"
        case .review: "ask: " + (decision.suggestions.compactMap(name).joined(separator: " or ").nilIfEmpty ?? "no suggestion")
        case .notSchoolwork: "not schoolwork"
        }
        let mark = wronglyFiled(level) ? "  ✗ WRONG" : (filed(level) == expected && expected != nil ? "  ✓" : "")
        return verdict + mark
    }
}

struct Report {
    let results: [Result]
    let profile: Profile
    let modelNote: String
    /// The settings sorted with, such as "NSW HSC (34 subjects)".
    var profileName: String?
    /// Every subject sorted into, for the full report.
    var subjectList: String?

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: .now)
    }

    var schoolwork: [Result] { results.filter(\.isSchoolwork) }
    var notSchoolwork: [Result] { results.filter { !$0.isSchoolwork } }

    // MARK: Numbers

    struct LevelStats {
        var filed = 0
        var filedCorrectly = 0
        var wronglyFiled = 0
        var askedWithCorrectChoice = 0
        var askedWithoutCorrectChoice = 0
        var schoolworkLeftAlone = 0
        var nonSchoolworkFiled = 0
        var clearCount = 0
        var clearFiled = 0

        var precision: Double { filed == 0 ? 0 : Double(filedCorrectly) / Double(filed) }
    }

    func stats(_ level: AutoFileLevel, in subset: [Result]? = nil) -> LevelStats {
        var stats = LevelStats()
        for result in subset ?? results {
            let filed = result.filed(level)
            if filed != nil { stats.filed += 1 }
            if result.isSchoolwork {
                if filed == result.expected { stats.filedCorrectly += 1 }
                if result.wronglyFiled(level) { stats.wronglyFiled += 1 }
                if result.reviewOffersCorrectSubject(level) { stats.askedWithCorrectChoice += 1 }
                if result.decisions[level]?.outcome == .review && !result.reviewOffersCorrectSubject(level) { stats.askedWithoutCorrectChoice += 1 }
                if result.decisions[level]?.outcome == .notSchoolwork { stats.schoolworkLeftAlone += 1 }
                if result.tags.contains("clear") {
                    stats.clearCount += 1
                    if filed == result.expected { stats.clearFiled += 1 }
                }
            } else if filed != nil {
                stats.nonSchoolworkFiled += 1
                stats.wronglyFiled += 1
            }
        }
        return stats
    }

    func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "–" : String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    func topChoiceAccuracy(_ subset: [Result]) -> (correct: Int, total: Int) {
        let school = subset.filter(\.isSchoolwork)
        return (school.filter { $0.topChoice == $0.expected }.count, school.count)
    }

    // MARK: Summary

    func summary() -> String {
        let top = topChoiceAccuracy(results)
        var lines = [
            "",
            "Folio accuracy\(profileName.map { " with \($0)" } ?? ""): \(results.count) files (\(schoolwork.count) schoolwork, \(notSchoolwork.count) not). AI: \(modelNote)",
            "Top choice correct for schoolwork: \(top.correct)/\(top.total) (\(percent(top.correct, top.total)))",
            "",
            "Level      Auto-filed   Right when filed   Wrong files   Clear-cut auto-filed   Asked (right choice offered)",
        ]
        func column(_ text: String, _ width: Int) -> String {
            text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
        }
        for level in AutoFileLevel.allCases {
            let s = stats(level)
            lines.append(
                column(level.rawValue, 11)
                    + column("\(s.filed)/\(results.count)", 13)
                    + column(percent(s.filedCorrectly, s.filed), 19)
                    + column("\(s.wronglyFiled)", 14)
                    + column("\(s.clearFiled)/\(s.clearCount) (\(percent(s.clearFiled, s.clearCount)))", 23)
                    + "\(s.askedWithCorrectChoice + s.askedWithoutCorrectChoice) (\(s.askedWithCorrectChoice))"
            )
        }
        let declined = results.filter { $0.vote(.model)?.abstention?.kind == .declined }.count
        lines.append("")
        lines.append("AI declined \(declined) files. Median time per file: \(String(format: "%.2f", median(results.map { $0.extractionSeconds + $0.classificationSeconds }))) s")
        let asked = results.filter { $0.vote(.cloud) != nil }
        if !asked.isEmpty {
            let answered = asked.filter { $0.vote(.cloud)?.abstention == nil }
            let answeredSchoolwork = answered.filter(\.isSchoolwork)
            let right = answeredSchoolwork.filter { $0.name($0.vote(.cloud)?.top?.id) == $0.expected }.count
            let refused = asked.filter { $0.vote(.cloud)?.abstention?.kind == .declined }.count
            let filed = asked.filter { $0.filed(.careful) != nil }.count
            let wrong = asked.filter { $0.wronglyFiled(.careful) }.count
            lines.append("Claude was asked about \(asked.count) files left for review at Careful. It answered \(answered.count), choosing the right subject for \(right) of \(answeredSchoolwork.count) schoolwork files, and declined \(refused). Then \(filed) were filed at Careful, \(wrong) wrongly.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: One line per pack

    static let tableHeader = "Pack                      Subjects  Files  Top choice      Careful (wrong)   Balanced (wrong)   Eager (wrong)"

    /// How one pack did, for a table with a line per pack.
    func tableRow(_ name: String, subjects: Int) -> String {
        func column(_ text: String, _ width: Int) -> String {
            text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0)
        }
        let top = topChoiceAccuracy(results)
        func level(_ level: AutoFileLevel) -> String {
            let s = stats(level)
            return "\(s.filed) (\(s.wronglyFiled))"
        }
        return column(name, 26)
            + column("\(subjects)", 10)
            + column("\(results.count)", 7)
            + column("\(top.correct)/\(top.total) \(percent(top.correct, top.total))", 16)
            + column(level(.careful), 18)
            + column(level(.balanced), 19)
            + level(.eager)
    }

    // MARK: Markdown

    func markdown() -> String {
        var md: [String] = []
        let top = topChoiceAccuracy(results)
        md.append("# Folio sorting accuracy")
        md.append("")
        if let profileName {
            md.append("Subjects: \(profileName). \(subjectList ?? "")")
            md.append("")
        }
        md.append("\(results.count) files: \(schoolwork.count) schoolwork, \(notSchoolwork.count) not schoolwork. On-device AI: \(modelNote).")
        md.append("")
        md.append("**Top choice correct (schoolwork): \(top.correct)/\(top.total) (\(percent(top.correct, top.total)))**. This counts the subject with the most support, whether or not Folio would file it.")
        md.append("")
        md.append("## By auto-file level")
        md.append("")
        md.append("| Level | Auto-filed | Right when auto-filed | Wrongly filed | Clear-cut files auto-filed | Asked, right choice offered | Asked, right choice missing | Non-schoolwork filed |")
        md.append("|---|---|---|---|---|---|---|---|")
        for level in AutoFileLevel.allCases {
            let s = stats(level)
            md.append("| \(level.rawValue) | \(s.filed) | \(s.filedCorrectly)/\(s.filed) (\(percent(s.filedCorrectly, s.filed))) | \(s.wronglyFiled) | \(s.clearFiled)/\(s.clearCount) (\(percent(s.clearFiled, s.clearCount))) | \(s.askedWithCorrectChoice) | \(s.askedWithoutCorrectChoice) | \(s.nonSchoolworkFiled) |")
        }

        md.append("")
        md.append("## By kind of file (Balanced)")
        md.append("")
        md.append("| Tag | Files | Top choice right | Auto-filed | Right when auto-filed | Wrongly filed |")
        md.append("|---|---|---|---|---|---|")
        let tags = Set(results.flatMap(\.tags)).sorted()
        for tag in tags {
            let subset = results.filter { $0.tags.contains(tag) }
            let s = stats(.balanced, in: subset)
            let t = topChoiceAccuracy(subset)
            md.append("| \(tag) | \(subset.count) | \(t.total == 0 ? "–" : "\(t.correct)/\(t.total)") | \(s.filed) | \(percent(s.filedCorrectly, s.filed)) | \(s.wronglyFiled) |")
        }

        md.append("")
        md.append("## Voters")
        md.append("")
        md.append("| Voter | Voted | Right when voting (schoolwork) | Abstained | Declined (AI) | Said “not schoolwork” on schoolwork | Said “not schoolwork” on non-schoolwork |")
        md.append("|---|---|---|---|---|---|---|")
        for kind in [VoterKind.keywords, .examples, .model, .cloud] {
            let withVote = results.compactMap { r in r.vote(kind).map { (r, $0) } }
            guard !withVote.isEmpty else { continue }
            let voted = withVote.filter { $0.1.abstention == nil && $0.1.top != nil }
            let right = voted.filter { $0.0.isSchoolwork && $0.0.name($0.1.top?.id) == $0.0.expected }.count
            let votedOnSchool = voted.filter { $0.0.isSchoolwork }.count
            let abstained = withVote.filter { $0.1.abstention != nil }.count
            let declined = withVote.filter { $0.1.abstention?.kind == .declined }.count
            let falseUnsorted = withVote.filter { $0.0.isSchoolwork && $0.1.notSchoolwork >= 0.5 }.count
            let trueUnsorted = withVote.filter { !$0.0.isSchoolwork && $0.1.notSchoolwork >= 0.5 }.count
            md.append("| \(kind.rawValue) | \(voted.count) | \(right)/\(votedOnSchool) (\(percent(right, votedOnSchool))) | \(abstained) | \(declined) | \(falseUnsorted) | \(trueUnsorted)/\(notSchoolwork.count) |")
        }

        md.append("")
        md.append("## Document type")
        md.append("")
        let typed = results.filter { $0.expectedType != nil }
        let typeRight = typed.filter { $0.decisions[.balanced]?.facets.documentType == $0.expectedType }.count
        md.append("Right for \(typeRight)/\(typed.count) (\(percent(typeRight, typed.count))) of files with a known type.")

        md.append("")
        md.append("## Speed")
        md.append("")
        md.append("Median extraction \(String(format: "%.2f", median(results.map(\.extractionSeconds)))) s, median classification \(String(format: "%.2f", median(results.map(\.classificationSeconds)))) s, slowest file \(String(format: "%.1f", results.map { $0.extractionSeconds + $0.classificationSeconds }.max() ?? 0)) s.")

        md.append("")
        md.append("## Mistakes")
        for level in AutoFileLevel.allCases {
            let wrong = results.filter { $0.wronglyFiled(level) }
            md.append("")
            md.append("### Wrongly filed at \(level.rawValue): \(wrong.count)")
            for r in wrong {
                md.append("- `\(r.path)`: filed to **\(r.filed(level) ?? "?")**, should be \(r.expected ?? "left alone"). \(r.decisions[level]?.reasons.joined(separator: "; ") ?? "")")
            }
        }
        let missed = schoolwork.filter { $0.topChoice != $0.expected }
        md.append("")
        md.append("### Top choice wrong or missing: \(missed.count)")
        for r in missed {
            let keywords = r.name(r.vote(.keywords)?.top?.id) ?? (r.vote(.keywords)?.abstention?.reason ?? "–")
            let model = r.name(r.vote(.model)?.top?.id) ?? (r.vote(.model)?.abstention?.reason ?? (r.vote(.model)?.notSchoolwork ?? 0 >= 0.5 ? "not schoolwork" : "–"))
            let found = r.vote(.keywords)?.reasons.prefix(2).joined(separator: "; ") ?? ""
            md.append("- `\(r.path)` (\(r.tags.joined(separator: ", "))): expected \(r.expected ?? "-"), keywords: \(keywords)\(found.isEmpty ? "" : " (\(found))"), AI: \(model), text read: \(r.evidence.text.count) chars via \(r.evidence.method.rawValue)")
        }
        return md.joined(separator: "\n") + "\n"
    }

    // MARK: CSV

    func csv() -> String {
        var rows = ["path,expected,tags,method,text_chars,keywords_top,keywords_share,keywords_strength,examples_top,examples_lead,examples_note,model_top,model_note,careful,balanced,eager,type_expected,type_found,year,exam,extract_s,classify_s"]
        for r in results {
            let keywords = r.vote(.keywords)
            let examples = r.vote(.examples)
            let model = r.vote(.model)
            let modelNote = model?.abstention.map { [$0.reason, $0.detail].compactMap { $0 }.joined(separator: ": ") }
                ?? ((model?.notSchoolwork ?? 0) >= 0.5 ? "not schoolwork" : "")
            let facets = r.decisions[.balanced]?.facets
            let fields: [String] = [
                r.path, r.expected ?? "", r.tags.joined(separator: " "), r.evidence.method.rawValue, String(r.evidence.text.count),
                r.name(keywords?.top?.id) ?? "", String(format: "%.2f", keywords?.top?.score ?? 0), String(format: "%.1f", keywords?.strength ?? 0),
                r.name(examples?.top?.id) ?? "", String(format: "%.3f", examples?.strength ?? 0), examples?.abstention?.reason ?? "",
                r.name(model?.top?.id) ?? "", modelNote,
                r.describe(.careful), r.describe(.balanced), r.describe(.eager),
                r.expectedType ?? "", facets?.documentType ?? "", facets?.year.map(String.init) ?? "", facets?.exam ?? "",
                String(format: "%.2f", r.extractionSeconds), String(format: "%.2f", r.classificationSeconds),
            ]
            rows.append(fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
