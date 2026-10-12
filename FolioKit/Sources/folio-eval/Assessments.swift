import Foundation
import FolioKit

/// `folio-eval --assessments <file>`: measures how well Folio reads task
/// sheets, marking criteria and marked work, from labelled text in
/// Tools/TestSet/assessments.json.
enum AssessmentEval {
    struct File: Decodable {
        var now: String
        var timeZone: String
        var samples: [Sample]
    }

    struct Sample: Decodable {
        var id: String
        var style: String
        var file: String
        var text: String
        var facets: SampleFacets?
        var expect: Expected?
        /// "tuning", or "held out" for files written after the reader was tuned.
        var set: String?
    }

    struct SampleFacets: Decodable {
        var documentType: String?
        var year: Int?
        var exam: String?
    }

    struct Expected: Decodable {
        var titleWords: [String]?
        var kind: String?
        var due: String?
        var weighting: Double?
        var totalMarks: Double?
        var lengthMinutes: Int?
        var role: String?
        var mark: ExpectedMark?
    }

    struct ExpectedMark: Decodable {
        var score: Double?
        var outOf: Double?
        var grade: String?
    }

    /// Prints the report and returns the exit status.
    static func run(_ url: URL) -> Int32 {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            print("Couldn't read \(url.path)")
            return 66
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: file.timeZone) ?? .current
        guard let now = date(file.now, calendar: calendar) else {
            print("Couldn't read the date \(file.now)")
            return 65
        }

        print("Assessment reader, \(file.samples.count) labelled files, read as if it were \(describe(now, calendar))")
        let sets = file.samples.reduce(into: [String]()) { names, sample in
            let name = sample.set ?? "tuning"
            if !names.contains(name) { names.append(name) }
        }
        for name in sets {
            let title = name == "tuning" ? "Tuning set" : "\(name.prefix(1).uppercased())\(name.dropFirst()) (written after the reader was tuned on the sets above)"
            report(file.samples.filter { ($0.set ?? "tuning") == name }, title: title, now: now, calendar: calendar)
        }
        return 0
    }

    static func report(_ samples: [Sample], title: String, now: Date, calendar: Calendar) {
        var sheets = Tally(), others = Tally()
        var falseOffers: [String] = []
        var problems: [String] = []

        for sample in samples {
            let evidence = Evidence(fileName: sample.file, contentType: "com.adobe.pdf", text: sample.text, method: .embeddedText)
            let facets = Facets(documentType: sample.facets?.documentType, year: sample.facets?.year, exam: sample.facets?.exam)
            let reading = AssessmentReader.read(evidence, facets: facets, now: now, calendar: calendar)
            let found = reading?.assessment

            guard let expect = sample.expect else {
                others.total += 1
                if let found {
                    falseOffers.append("\(sample.id): offered “\(found.title)”, due \(describe(found.due, calendar))")
                } else if let role = reading?.role {
                    falseOffers.append("\(sample.id): called it \(role.rawValue)")
                } else {
                    others.right += 1
                }
                continue
            }

            if expect.due == nil {
                // Criteria or marked work.
                others.total += 1
                var wrong: [String] = []
                if found != nil { wrong.append("offered an assessment") }
                if reading?.role?.rawValue != expect.role { wrong.append("role \(reading?.role?.rawValue ?? "none"), expected \(expect.role ?? "none")") }
                if let mark = expect.mark {
                    let got = reading?.mark
                    if got?.score != mark.score || got?.outOf != mark.outOf || got?.grade != mark.grade {
                        wrong.append("mark \(got.map { "\($0.score.map { "\($0)" } ?? "-")/\($0.outOf.map { "\($0)" } ?? "-") \($0.grade ?? "")" } ?? "none")")
                    }
                }
                if wrong.isEmpty { others.right += 1 } else { problems.append("\(sample.id): \(wrong.joined(separator: "; "))") }
                continue
            }

            sheets.total += 1
            guard let found else {
                problems.append("\(sample.id) (\(sample.style)): nothing found")
                continue
            }
            sheets.found += 1
            var wrong: [String] = []
            let dueRight = dueMatches(found.due, expect.due!, calendar: calendar)
            if dueRight { sheets.due += 1 } else { wrong.append("due \(describe(found.due, calendar)), expected \(expect.due!)") }
            if found.kind.rawValue == expect.kind { sheets.kind += 1 } else { wrong.append("kind \(found.kind.rawValue), expected \(expect.kind ?? "?")") }
            let words = expect.titleWords ?? []
            if words.allSatisfy({ found.title.localizedCaseInsensitiveContains($0) }) { sheets.title += 1 } else { wrong.append("title “\(found.title)”") }
            if found.weighting == expect.weighting { sheets.weighting += 1 } else { wrong.append("weighting \(found.weighting.map { "\($0)" } ?? "none"), expected \(expect.weighting.map { "\($0)" } ?? "none")") }
            if expect.totalMarks == nil || found.totalMarks == expect.totalMarks { sheets.marks += 1 } else { wrong.append("total marks \(found.totalMarks.map { "\($0)" } ?? "none")") }
            if expect.lengthMinutes == nil || found.lengthMinutes == expect.lengthMinutes { sheets.length += 1 } else { wrong.append("length \(found.lengthMinutes.map { "\($0)" } ?? "none")") }
            if expect.role == nil || reading?.role?.rawValue == expect.role { sheets.role += 1 } else { wrong.append("role \(reading?.role?.rawValue ?? "none")") }
            if wrong.isEmpty { sheets.right += 1 } else { problems.append("\(sample.id) (\(sample.style)): \(wrong.joined(separator: "; "))") }
        }

        print("\n\(title): \(samples.count) files")
        print("Task sheets and exam notices: \(sheets.total)")
        print("  found \(sheets.found), date right \(sheets.due), kind right \(sheets.kind), title right \(sheets.title), weighting right \(sheets.weighting)")
        print("  total marks right \(sheets.marks), exam length right \(sheets.length), role right \(sheets.role)")
        print("  every detail right: \(sheets.right) of \(sheets.total)")
        print("Criteria, marked work and look-alikes: \(others.total), handled right \(others.right)")
        if !falseOffers.isEmpty {
            print("Offered for files that aren't assessments:")
            falseOffers.forEach { print("  \($0)") }
        }
        if !problems.isEmpty {
            print("Misses:")
            problems.forEach { print("  \($0)") }
        }
    }

    struct Tally {
        var total = 0, found = 0, due = 0, kind = 0, title = 0, weighting = 0, marks = 0, length = 0, role = 0, right = 0
    }

    /// "2026-11-13" checks the day; "2026-11-13T15:00" the minute too.
    static func dueMatches(_ date: Date, _ expected: String, calendar: Calendar) -> Bool {
        guard let want = self.date(expected, calendar: calendar) else { return false }
        if expected.contains("T") {
            return abs(date.timeIntervalSince(want)) < 60
        }
        return calendar.isDate(date, inSameDayAs: want)
    }

    static func date(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        components.hour = parts.count > 3 ? parts[3] : 0
        components.minute = parts.count > 4 ? parts[4] : 0
        return calendar.date(from: components)
    }

    static func describe(_ date: Date, _ calendar: Calendar) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
