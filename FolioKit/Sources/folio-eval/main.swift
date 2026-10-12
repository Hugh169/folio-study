import Foundation
import FolioKit

// Measures how well Folio sorts labelled folders, without moving anything.
//
// usage: folio-eval <folder> [<folder>…] [--pack <id> | --all-packs [--with-model]] [--group-size N]
//                   [--no-model] [--limit N] [--every K] [--out <folder>]
//                   [--half even|odd] [--examples] [--margin X] [--min-similarity X]
//                   [--tag T] [--no-images] [--images-always]
//                   [--excerpt N] [--general] [--clues] [--ask-type] [--schema-prompt]
//                   [--no-retry] [--retry-tagging] [--show-names]
//                   [--claude] [--claude-photos]
//
// --every K takes every Kth file, for a quick sample across all subjects, and
// --tag T only sorts files with that tag in the manifest, such as "recording".
// --no-images stops the AI looking at photos, leaving only the text read from
// them; --images-always shows it every photo, not just ones with little text.
// --half sorts only every other file. With --examples, Folio first learns from
// the other half's schoolwork, as if the student had already filed it, so the
// "similar past files" voter can be measured; --margin and --min-similarity
// tune when it votes. The remaining options change how the on-device AI is
// asked, to compare speed and accuracy.
//
// --pack <id> sorts with a curriculum pack's courses instead of the five
// sample subjects. Files are labelled with subject areas such as "History",
// and each area stands for the course most students take in that pack
// (Modern History in the HSC). Files from areas the pack doesn't teach are
// left out. --all-packs measures every pack and prints a line for each. It
// leaves the on-device AI off unless --with-model is given, since the AI is
// asked about every file again for each pack. Files are read only once.
// --group-size N shares a pack's subject areas among students of up to N
// subjects each, as real students have, instead of one student taking them
// all: each file is sorted by the student who takes its subject, and files
// that aren't schoolwork by every student.
//
// --claude asks Claude Haiku about the files left for review at Careful, as
// the app does when Claude is on, using the API key in ANTHROPIC_API_KEY. It
// costs money, though only the files left for review are sent: well under
// 1 US cent for the test set, and that again for each pack.
// --claude-photos also shows Claude photos with almost no text.
//
// Each folder holds one subfolder per subject, named like the profile's
// subjects or a pack's subject areas, plus "_Unsorted" for files that
// shouldn't be filed. An optional manifest.json (written by folio-testset)
// adds tags and expected document types.

// --assessments <file> instead measures how well Folio reads task sheets,
// marking criteria and marked work, from Tools/TestSet/assessments.json.
if let index = CommandLine.arguments.firstIndex(of: "--assessments") {
    guard index + 1 < CommandLine.arguments.count else {
        print("usage: folio-eval --assessments <assessments.json>")
        exit(64)
    }
    exit(AssessmentEval.run(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
}

// --search <folder> <search.json> measures finding files by name, by the words
// in them and by meaning, with the searches in Tools/TestSet/search.json.
if let index = CommandLine.arguments.firstIndex(of: "--search") {
    guard index + 2 < CommandLine.arguments.count else {
        print("usage: folio-eval --search <folder> <search.json>")
        exit(64)
    }
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    exit(await SearchEval.run(folder: folder, queriesURL: URL(fileURLWithPath: CommandLine.arguments[index + 2])))
}

// --cards <cards.json> writes flashcards from the notes in Tools/TestSet/cards.json
// with the on-device AI. --parts N and --part-length N change how much is read.
if let index = CommandLine.arguments.firstIndex(of: "--cards") {
    guard index + 1 < CommandLine.arguments.count else {
        print("usage: folio-eval --cards <cards.json> [--parts N] [--part-length N]")
        exit(64)
    }
    var cardOptions = CardWriter.Options()
    if let parts = CommandLine.arguments.firstIndex(of: "--parts").flatMap({ CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil }) {
        cardOptions.maxParts = parts
    }
    if let length = CommandLine.arguments.firstIndex(of: "--part-length").flatMap({ CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil }) {
        cardOptions.partLength = length
    }
    exit(await CardEval.run(URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: cardOptions))
}

struct Options {
    var folders: [URL] = []
    var packID: String?
    var allPacks = false
    var withModel = false
    var groupSize: Int?
    var useModel = true
    var limit: Int?
    var every = 1
    var output: URL?
    var half: Int?
    var tag: String?
    var learnsFromOtherHalf = false
    var examples = ExampleVoter.Settings()
    var model = ModelVoter.Options()
    var asksClaude = false
    var claudeSeesPhotos = false

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 1
        /// The value after an option, such as the 5 in "--every 5".
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--no-model": options.useModel = false
            case "--no-clues": options.model.asksForClues = false
            case "--no-schema-prompt": options.model.includesSchemaInPrompt = false
            case "--general": options.model.usesContentTagging = false
            case "--clues": options.model.asksForClues = true
            case "--ask-type": options.model.asksForDocumentType = true
            case "--no-retry": options.model.retriesRefusalsPlainly = false
            case "--retry-tagging": options.model.plainRetryUsesGeneralModel = false
            case "--show-names": options.model.hidesFileNameAboveTextLength = nil
            case "--schema-prompt": options.model.includesSchemaInPrompt = true
            case "--claude": options.asksClaude = true
            case "--claude-photos":
                options.asksClaude = true
                options.claudeSeesPhotos = true
            case "--all-packs": options.allPacks = true
            case "--with-model": options.withModel = true
            case "--examples": options.learnsFromOtherHalf = true
            case "--no-images": options.model.looksAtImagesBelowTextLength = nil
            case "--images-always": options.model.looksAtImagesBelowTextLength = .max
            case "--pack":
                guard let id = value() else { return nil }
                options.packID = id
            case "--group-size":
                guard let number = value() else { return nil }
                options.groupSize = Int(number).map { max($0, 1) }
            case "--excerpt":
                guard let number = value() else { return nil }
                options.model.excerptLength = Int(number) ?? 1500
            case "--every":
                guard let number = value() else { return nil }
                options.every = max(1, Int(number) ?? 1)
            case "--half":
                guard let half = value() else { return nil }
                options.half = half == "odd" ? 1 : 0
            case "--tag":
                guard let tag = value() else { return nil }
                options.tag = tag
            case "--margin":
                guard let number = value() else { return nil }
                options.examples.margin = Float(number) ?? 0.10
            case "--min-similarity":
                guard let number = value() else { return nil }
                options.examples.minimumSimilarity = Float(number) ?? 0.1
            case "--limit":
                guard let number = value() else { return nil }
                options.limit = Int(number)
            case "--out":
                guard let path = value() else { return nil }
                options.output = URL(fileURLWithPath: path, isDirectory: true)
            case let path where !path.hasPrefix("--"):
                options.folders.append(URL(fileURLWithPath: path, isDirectory: true))
            default:
                return nil
            }
            index += 1
        }
        if options.allPacks && !options.withModel { options.useModel = false }
        return options.folders.isEmpty ? nil : options
    }
}

guard let options = Options.parse(CommandLine.arguments) else {
    print("usage: folio-eval <folder> [<folder>…] [--pack <id> | --all-packs [--with-model]] [--group-size N] [--no-model] [--limit N] [--every K] [--out <folder>] [--half even|odd] [--examples] [--margin X] [--min-similarity X] [--tag T] [--no-images] [--images-always] [--excerpt N] [--general] [--clues] [--ask-type] [--schema-prompt] [--no-retry] [--retry-tagging] [--show-names] [--claude] [--claude-photos]")
    exit(64)
}

let allFiles = Manifest.testFiles(in: options.folders)
var files = allFiles.enumerated().filter { $0.offset % options.every == 0 }.map(\.element)
var pastFiles: [TestFile] = []
if let half = options.half {
    files = allFiles.enumerated().filter { $0.offset % 2 == half }.map(\.element)
    pastFiles = allFiles.enumerated().filter { $0.offset % 2 != half }.map(\.element)
}
if let tag = options.tag {
    files = files.filter { $0.label?.tags.contains(tag) == true }
}
if let limit = options.limit { files = Array(files.prefix(limit)) }

let packs = PackLibrary.packs.filter { !$0.subjects.isEmpty }
let areas = Set(allFiles.compactMap(\.subject))

/// One report: the sample subjects, a pack, or a pack shared among students.
struct Measurement {
    let id: String
    let name: String
    let runs: [Run]
}

@MainActor func measurement(for pack: CurriculumPack) -> Measurement {
    if let size = options.groupSize {
        let runs = Run.groups(of: pack, areas: areas, size: size)
        return Measurement(id: pack.id, name: "\(pack.name), \(runs.count) students of up to \(size) subjects", runs: runs)
    }
    let run = Run.pack(pack, areas: areas)
    return Measurement(id: pack.id, name: "\(pack.name) (\(run.profile.subjects.count) subjects)", runs: [run])
}

var measurements = [Measurement(id: "sample", name: "Sample subjects (5 subjects)", runs: [Run.starter()])]
if options.allPacks {
    measurements = packs.map(measurement(for:))
} else if let id = options.packID {
    guard let pack = packs.first(where: { $0.id == id }) else {
        print("There's no pack “\(id)” with courses. Packs: \(packs.map(\.id).joined(separator: ", "))")
        exit(64)
    }
    measurements = [measurement(for: pack)]
}

let model: ModelVoter? = options.useModel ? ModelVoter(options: options.model) : nil
var modelNote = "off (--no-model)"
if options.useModel {
    let settings = [
        options.model.usesContentTagging ? "content tagging" : "general",
        options.model.retriesRefusalsPlainly ? (options.model.plainRetryUsesGeneralModel ? "plain retry with general model" : "plain retry") : nil,
        "excerpt \(options.model.excerptLength)",
        options.model.hidesFileNameAboveTextLength.map { "hides file name above \($0) characters" },
        options.model.asksForClues ? "clues" : nil,
        options.model.asksForDocumentType ? "asks for type" : nil,
        options.model.includesSchemaInPrompt ? "schema in prompt" : nil,
        options.model.looksAtImagesBelowTextLength.map { $0 == .max ? "always looks at photos" : "looks at photos with under \($0) characters of text" },
    ].compactMap { $0 }
    modelNote = "on (\(settings.joined(separator: ", ")))"
} else if options.allPacks {
    modelNote = "off (add --with-model to use it)"
}
let modelIsAvailable: Bool
if let model, let reason = await model.unavailableReason {
    modelNote = "unavailable: \(reason)"
    modelIsAvailable = false
} else {
    modelIsAvailable = model != nil
}

var claude: ClaudeVoter?
let claudeLedgerName = "folio-eval-claude-usage"
var claudeLedger: ClaudeUsageLedger?
if options.asksClaude {
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        print("--claude reads your API key from ANTHROPIC_API_KEY, which isn't set.")
        exit(64)
    }
    if let problem = await ClaudeVoter.test(key: key) {
        print("Claude isn't working with this key: \(problem.message)")
        exit(1)
    }
    let defaults = UserDefaults(suiteName: claudeLedgerName) ?? .standard
    defaults.removePersistentDomain(forName: claudeLedgerName)
    claudeLedger = ClaudeUsageLedger(defaults: defaults)
    var claudeOptions = ClaudeVoter.Options()
    claudeOptions.sendsPhotosBelowTextLength = options.claudeSeesPhotos ? 40 : nil
    claude = ClaudeVoter(key: key, options: claudeOptions, ledger: claudeLedger)
    modelNote += "; Claude Haiku for files left for review at Careful" + (options.claudeSeesPhotos ? ", with photos" : "")
}

/// What was read from a file, kept so each file is read once however many
/// profiles sort it.
struct Reading {
    let evidence: Evidence
    let failed: Bool
    let seconds: Double
}

let extractor = Extractor()
var readings: [URL: Reading] = [:]

@MainActor func read(_ url: URL) async -> Reading {
    if let reading = readings[url] { return reading }
    let clock = ContinuousClock()
    let start = clock.now
    let reading: Reading
    do {
        reading = Reading(evidence: try await extractor.extract(from: url), failed: false, seconds: (clock.now - start).seconds)
    } catch {
        reading = Reading(evidence: Evidence(fileName: url.lastPathComponent, contentType: "public.data"), failed: true, seconds: (clock.now - start).seconds)
    }
    readings[url] = reading
    return reading
}

/// Sorts the files with one run's settings, as the app would. With `group`,
/// paths start with the group's number, since files that aren't schoolwork
/// are sorted by every group.
@MainActor func evaluate(_ run: Run, showsEachFile: Bool, group: Int? = nil) async -> (results: [Result], withoutExamples: [Result]?, note: String) {
    let profile = run.profile
    if let model, modelIsAvailable { await model.prewarm(for: profile) }
    var note = modelNote
    var examples: ExampleVoter?
    if options.learnsFromOtherHalf {
        // Learn from the other half's schoolwork, as if the student had filed it.
        let voter = ExampleVoter(settings: options.examples)
        var learned = 0
        for file in pastFiles {
            guard let label = file.subject,
                  let subject = run.subjectName(label).flatMap(profile.subject(named:)),
                  let embedding = await voter.embedding(for: await read(file.url).evidence)
            else { continue }
            await voter.add(ExampleIndex.Example(subjectID: subject.id, name: file.url.lastPathComponent, embedding: embedding))
            learned += 1
        }
        examples = voter
        note += "; learned from \(learned) past files (margin \(options.examples.margin), min similarity \(options.examples.minimumSimilarity))"
    }
    let classifier = Classifier.standard(model: model, examples: examples)

    // Files labelled with a subject this profile doesn't have are left out,
    // and so are files that might be schoolwork for one it does have.
    let cases: [(file: TestFile, expected: String?)] = files.compactMap { file in
        if let related = file.label?.related, run.subjectName(related) != nil { return nil }
        guard let label = file.subject else { return (file, nil) }
        return run.subjectName(label).map { (file, $0) }
    }
    if showsEachFile {
        let leftOut = files.count - cases.count
        FileHandle.standardError.write(Data("Sorting \(cases.count) files with \(run.name) (AI \(note))…\(leftOut > 0 ? " Leaving out \(leftOut) from subject areas it doesn't have, or that might be its schoolwork." : "")\n".utf8))
    }

    var results: [Result] = []
    for (number, item) in cases.enumerated() {
        let reading = await read(item.file.url)
        let clock = ContinuousClock()
        let start = clock.now
        var votes = await classifier.votes(for: reading.evidence, profile: profile)
        // As in the app, Claude is asked only about files the others leave for review.
        if let claude, Arbiter(level: .careful).decide(votes, evidence: reading.evidence, profile: profile).outcome == .review {
            votes = Classifier.votes(votes, adding: await claude.vote(on: reading.evidence, profile: profile))
        }
        let classificationSeconds = (clock.now - start).seconds

        let decisions = Dictionary(uniqueKeysWithValues: AutoFileLevel.allCases.map {
            ($0, Arbiter(level: $0).decide(votes, evidence: reading.evidence, profile: profile))
        })
        let result = Result(
            path: group.map { "\($0): \(item.file.path)" } ?? item.file.path,
            expected: item.expected,
            tags: item.file.label?.tags ?? [],
            expectedType: item.file.label?.type,
            evidence: reading.evidence,
            extractionFailed: reading.failed,
            votes: votes,
            decisions: decisions,
            extractionSeconds: reading.seconds,
            classificationSeconds: classificationSeconds,
            profile: profile
        )
        results.append(result)
        if showsEachFile {
            FileHandle.standardError.write(Data("[\(number + 1)/\(cases.count)] \(item.file.path) → \(result.describe(.balanced))\n".utf8))
        }
    }

    // With learning on, also show what the same votes decide without it.
    return (results, examples == nil ? nil : results.map { $0.without(.examples) }, note)
}

/// Sorts the files with each of a measurement's runs, into one report.
@MainActor func report(_ measurement: Measurement, showsEachFile: Bool) async -> (report: Report, withoutExamples: Report?) {
    var results: [Result] = []
    var withoutExamples: [Result]?
    var note = modelNote
    let isGrouped = measurement.runs.count > 1
    for (index, run) in measurement.runs.enumerated() {
        let outcome = await evaluate(run, showsEachFile: showsEachFile, group: isGrouped ? index + 1 : nil)
        results += outcome.results
        if let without = outcome.withoutExamples { withoutExamples = (withoutExamples ?? []) + without }
        note = outcome.note
    }
    let names = measurement.runs.map { $0.profile.subjects.map(\.name).joined(separator: ", ") }
    let subjectList = isGrouped ? names.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "; ") : names.first ?? ""
    let report = Report(results: results, profile: measurement.runs[0].profile, modelNote: note, profileName: measurement.name, subjectList: subjectList)
    let without = withoutExamples.map {
        Report(results: $0, profile: measurement.runs[0].profile, modelNote: note + " — same files, without similar past files", profileName: measurement.name, subjectList: subjectList)
    }
    return (report, without)
}

let output = options.output ?? options.folders[0]
    .deletingLastPathComponent()
    .appending(path: "reports/\(Report.timestamp())", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

if measurements.count == 1 {
    let (report, withoutExamples) = await report(measurements[0], showsEachFile: true)
    try report.markdown().write(to: output.appending(path: "report.md"), atomically: true, encoding: .utf8)
    try report.csv().write(to: output.appending(path: "results.csv"), atomically: true, encoding: .utf8)
    print(report.summary())
    if let withoutExamples {
        try withoutExamples.markdown().write(to: output.appending(path: "report-without-examples.md"), atomically: true, encoding: .utf8)
        print(withoutExamples.summary())
    }
} else {
    FileHandle.standardError.write(Data("Sorting \(files.count) files with each of \(measurements.count) packs (AI \(modelNote))…\n".utf8))
    var lines = [Report.tableHeader]
    for measurement in measurements {
        let (report, _) = await report(measurement, showsEachFile: false)
        let folder = output.appending(path: measurement.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try report.markdown().write(to: folder.appending(path: "report.md"), atomically: true, encoding: .utf8)
        try report.csv().write(to: folder.appending(path: "results.csv"), atomically: true, encoding: .utf8)
        let subjects = Set(measurement.runs.flatMap { $0.profile.subjects.map(\.name) }).count
        let line = report.tableRow(measurement.runs.count > 1 ? "\(measurement.runs[0].name.replacingOccurrences(of: " student 1", with: "")) ×\(measurement.runs.count)" : measurement.runs[0].name, subjects: subjects)
        lines.append(line)
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
    let table = lines.joined(separator: "\n")
    try "# Folio sorting accuracy by pack\n\nAI: \(modelNote)\n\n```\n\(table)\n```\n".write(to: output.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    print("\n" + table)
}
if let claudeLedger {
    let usage = claudeLedger.usage()
    print("Claude: \(usage.requests) requests, \(usage.inputTokens) tokens in and \(usage.outputTokens) out, about US$\(String(format: "%.4f", usage.cost))")
    UserDefaults(suiteName: claudeLedgerName)?.removePersistentDomain(forName: claudeLedgerName)
}
print("Full report: \(output.appending(path: measurements.count == 1 ? "report.md" : "summary.md").path(percentEncoded: false))")
