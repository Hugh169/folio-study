import Foundation

/// Reads and classifies files in the background. At most two files are read at
/// once, and files are classified one at a time, so the on-device AI only ever
/// answers one question at a time. It never moves anything: `Librarian` acts
/// on what it reports.
public actor SortingPipeline {
    public struct Job: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let url: URL

        public init(id: UUID = UUID(), url: URL) {
            self.id = id
            self.url = url
        }
    }

    public struct Analysis: Sendable {
        public var evidence: Evidence
        public var decision: Decision
        public var contentHash: String?
        /// For learning from the file if the student files it.
        public var embedding: TextEmbedder.Embedding?
    }

    public enum Event: Sendable {
        case progress(Job.ID, String)
        case analysed(Job, Analysis)
        /// A file with the same contents was already filed, or is already being
        /// sorted, in which case `sameAs` is that file's name.
        case duplicate(Job, contentHash: String, sameAs: String?)
        case failed(Job, String)
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private var classifier: Classifier
    /// Claude, when the student turned it on. It's asked only about files the
    /// other voters leave for review.
    private var secondOpinion: (any Voter)?
    private var profile: Profile
    private let extractor: Extractor
    private let examples: ExampleVoter?
    private let maxConcurrentReads: Int
    /// The longest judging one file takes before Folio gives up on it: the
    /// on-device AI's questions have their own limits, but comparing with
    /// filed files and asking Claude use services that could stall too.
    private let judgingLimit: Duration
    /// Contents already filed or in progress.
    private var knownHashes: Set<String>
    /// Files being sorted now, by their contents.
    private var inProgress: [String: String] = [:]

    private var waiting: [Job] = []
    private var reading = 0
    private var readyToClassify: [(Job, Evidence, String?)] = []
    private var isClassifying = false

    public init(
        classifier: Classifier,
        secondOpinion: (any Voter)? = nil,
        examples: ExampleVoter? = nil,
        profile: Profile,
        knownHashes: Set<String> = [],
        extractor: Extractor = Extractor(),
        maxConcurrentReads: Int = 2,
        judgingLimit: Duration = .seconds(480)
    ) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.classifier = classifier
        self.secondOpinion = secondOpinion
        self.examples = examples
        self.profile = profile
        self.knownHashes = knownHashes
        self.extractor = extractor
        self.maxConcurrentReads = maxConcurrentReads
        self.judgingLimit = judgingLimit
    }

    deinit {
        continuation.finish()
    }

    public func enqueue(_ jobs: [Job]) {
        for job in jobs {
            continuation.yield(.progress(job.id, String(localized: "Waiting…", bundle: .module)))
        }
        waiting += jobs
        pump()
    }

    /// Settings changes apply to files that haven't been classified yet.
    public func update(profile: Profile) {
        self.profile = profile
    }

    public func update(classifier: Classifier) {
        self.classifier = classifier
    }

    public func update(secondOpinion: (any Voter)?) {
        self.secondOpinion = secondOpinion
    }

    /// Treat files with these contents as already filed.
    public func remember(_ hash: String) {
        knownHashes.insert(hash)
    }

    /// The file with these contents was put back, skipped or left alone, so the
    /// same contents can be sorted again.
    public func forget(_ hash: String) {
        knownHashes.remove(hash)
    }

    public var isIdle: Bool {
        waiting.isEmpty && reading == 0 && readyToClassify.isEmpty && !isClassifying
    }

    // MARK: Scheduling

    private func pump() {
        while reading < maxConcurrentReads, !waiting.isEmpty {
            let job = waiting.removeFirst()
            reading += 1
            Task { await read(job) }
        }
        if !isClassifying, !readyToClassify.isEmpty {
            isClassifying = true
            let (job, evidence, hash) = readyToClassify.removeFirst()
            Task { await classify(job, evidence, hash) }
        }
    }

    private func read(_ job: Job) async {
        defer {
            reading -= 1
            pump()
        }
        let continuation = continuation
        let hash = await Self.hash(of: job.url)
        if let hash {
            guard !knownHashes.contains(hash) else {
                continuation.yield(.duplicate(job, contentHash: hash, sameAs: inProgress[hash]))
                return
            }
            knownHashes.insert(hash)
            inProgress[hash] = job.url.lastPathComponent
        }
        do {
            let evidence = try await Self.extract(job.url, with: extractor) { message in
                continuation.yield(.progress(job.id, message))
            }
            readyToClassify.append((job, evidence, hash))
        } catch {
            if let hash {
                knownHashes.remove(hash)
                inProgress[hash] = nil
            }
            continuation.yield(.failed(job, String(localized: "Couldn't read this file", bundle: .module)))
        }
    }

    private func classify(_ job: Job, _ evidence: Evidence, _ hash: String?) async {
        defer {
            isClassifying = false
            pump()
        }
        let continuation = continuation
        let (profile, classifier, secondOpinion, examples) = (self.profile, self.classifier, self.secondOpinion, self.examples)
        let judged = try? await AIDeadline.run(within: judgingLimit) { () -> (Decision, TextEmbedder.Embedding?) in
            var votes = await classifier.votes(for: evidence, profile: profile) { kind in
                switch kind {
                case .examples: continuation.yield(.progress(job.id, String(localized: "Comparing with files you've filed…", bundle: .module)))
                case .model: continuation.yield(.progress(job.id, String(localized: "Asking the on-device AI…", bundle: .module)))
                case .rules, .keywords, .timetable: break
                case .cloud: continuation.yield(.progress(job.id, String(localized: "Asking Claude…", bundle: .module)))
                }
            }
            let arbiter = Arbiter(level: profile.autoFileLevel)
            var decision = arbiter.decide(votes, evidence: evidence, profile: profile)
            if decision.outcome == .review, let secondOpinion {
                continuation.yield(.progress(job.id, String(localized: "Asking Claude…", bundle: .module)))
                votes = Classifier.votes(votes, adding: await secondOpinion.vote(on: evidence, profile: profile))
                decision = arbiter.decide(votes, evidence: evidence, profile: profile)
            }
            return (decision, await examples?.embedding(for: evidence))
        }
        if let hash { inProgress[hash] = nil }
        guard let (decision, embedding) = judged else {
            // Let the same contents be sorted again later.
            if let hash { knownHashes.remove(hash) }
            continuation.yield(.failed(job, String(localized: "Couldn't sort this file in time", bundle: .module)))
            return
        }
        continuation.yield(.analysed(job, Analysis(evidence: evidence, decision: decision, contentHash: hash, embedding: embedding)))
    }

    // MARK: Work done off the actor

    private nonisolated static func hash(of url: URL) async -> String? {
        await Blocking.run { try? ContentHash.sha256(of: url) } ?? nil
    }

    private nonisolated static func extract(_ url: URL, with extractor: Extractor, progress: @escaping @Sendable (String) -> Void) async throws -> Evidence {
        try await extractor.extract(from: url, progress: progress)
    }
}
