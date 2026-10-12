import Foundation

/// Compares a file with files the student has already filed, and votes for the
/// subject whose files it's most like. It only votes when one subject is
/// clearly closer than the rest, so it learns each student's own files without
/// adding noise while it has few examples.
///
/// Tuned with folio-eval learning from half the test set (about 11 files per
/// subject) and sorting the other half: at these settings it voted on 63% of
/// schoolwork and was right 96% of the time, and it never agreed with the
/// keyword voter on a wrong subject.
public actor ExampleVoter: Voter {
    public nonisolated let kind = VoterKind.examples

    public struct Settings: Sendable {
        /// How many of each subject's closest files are averaged.
        public var neighbours = 3
        /// It doesn't vote until it has at least this many examples…
        public var minimumExamples = 4
        /// …across at least this many subjects.
        public var minimumSubjects = 2
        /// How far ahead of the next subject the closest one must be.
        public var margin: Float = 0.10
        /// How similar the closest subject's files must be.
        public var minimumSimilarity: Float = 0.1
        /// Files with less text than this, such as a single formula, are too
        /// short to compare reliably.
        public var minimumTextLength = 50

        public init() {}
    }

    public let settings: Settings
    private var index: ExampleIndex
    private let embedder: TextEmbedder
    /// Recent files' embeddings, so a file isn't embedded twice when it's
    /// voted on and then kept as an example.
    private var recent: [(Evidence, TextEmbedder.Embedding)] = []

    public init(embedder: TextEmbedder = TextEmbedder(), examples: [ExampleIndex.Example] = [], settings: Settings = Settings()) {
        self.embedder = embedder
        self.index = ExampleIndex(examples)
        self.settings = settings
    }

    public var exampleCount: Int { index.count }

    public func replaceExamples(with examples: [ExampleIndex.Example]) {
        index = ExampleIndex(examples)
    }

    public func add(_ example: ExampleIndex.Example) {
        index.add(example)
    }

    public func removeExamples(_ ids: Set<UUID>) {
        index.removeAll { ids.contains($0.id) }
    }

    public func removeExamples(of subject: Subject.ID) {
        index.removeAll { $0.subjectID == subject }
    }

    /// The file's embedding, worked out once and remembered for a short while.
    public func embedding(for evidence: Evidence) async -> TextEmbedder.Embedding? {
        if let cached = recent.first(where: { $0.0 == evidence })?.1 { return cached }
        guard let embedding = await embedder.embed(Self.text(for: evidence), language: evidence.language) else { return nil }
        recent.append((evidence, embedding))
        if recent.count > 16 { recent.removeFirst() }
        return embedding
    }

    public func vote(on evidence: Evidence, profile: Profile) async -> Vote {
        let subjects = Set(profile.sortableSubjects.map(\.id))
        let usable = index.examples.filter { subjects.contains($0.subjectID) }
        guard usable.count >= settings.minimumExamples, Set(usable.map(\.subjectID)).count >= settings.minimumSubjects else {
            return .abstained(.examples, .noEvidence, String(localized: "Not enough past files to compare with yet", bundle: .module))
        }
        guard evidence.text.count >= settings.minimumTextLength else {
            return .abstained(.examples, .noEvidence, String(localized: "Too little text to compare with past files", bundle: .module))
        }
        guard let embedding = await embedding(for: evidence) else {
            return .abstained(.examples, .unavailable, String(localized: "Couldn't compare it with past files", bundle: .module))
        }
        let matches = index.matches(for: embedding, neighbours: settings.neighbours, among: subjects)
        guard let best = matches.first, let subject = profile.subject(best.subjectID) else {
            return .abstained(.examples, .noEvidence, String(localized: "Not like any past files", bundle: .module))
        }
        let lead = best.similarity - (matches.dropFirst().first?.similarity ?? -1)
        guard best.similarity >= settings.minimumSimilarity, lead >= settings.margin else {
            return .abstained(.examples, .noEvidence, String(localized: "Not clearly like any one subject's files", bundle: .module))
        }
        return Vote(
            voter: .examples,
            scores: [subject.id: 1],
            strength: Double(lead),
            reasons: [String(localized: "Like “\(best.nearest.name)” in \(subject.name)", bundle: .module, comment: "A past file this one is like, such as Like “Week 3 notes.pdf” in Physics")]
        )
    }

    /// The text that's compared: the file's own words when it has enough of
    /// them, so the file name doesn't count twice (the keyword voter reads it).
    static func text(for evidence: Evidence) -> String {
        if evidence.text.count >= 200 { return evidence.text }
        return [evidence.readableFileName, evidence.title, evidence.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
