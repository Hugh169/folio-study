import Foundation
import FoundationModels

/// Asks Apple's on-device model which subject a file belongs to. Its answer is
/// limited to the student's own subjects plus "Unsorted". Refusals and
/// unavailability become abstentions rather than errors, so the other voters
/// carry on without it.
public actor ModelVoter: Voter {
    public nonisolated let kind = VoterKind.model

    /// Trade-offs between speed and detail. The defaults were the fastest and most
    /// accurate in testing: on an M1, about 1.7 s per file against 6.5–8 s for the
    /// general model, and fewer wrong answers than asking for clues.
    public struct Options: Sendable {
        /// How many characters of the file's text the model reads.
        public var excerptLength = 1500
        /// Also ask for a few words of evidence, shown as the reason. Slower, and in
        /// testing the model sometimes just repeated a misleading file name.
        public var asksForClues = false
        /// Also ask what kind of document it is. Off because the words in the file
        /// were a better guide in testing.
        public var asksForDocumentType = false
        /// Describe the answer's fields in the prompt as well as enforcing them. Slower.
        public var includesSchemaInPrompt = false
        /// Use Apple's adapter tuned for tagging and classifying content. Much faster.
        public var usesContentTagging = true
        /// After a refusal, ask again as a plain question instead of a structured one.
        /// In testing, all 9 refusals (sensitive history topics and war poetry) were
        /// answered correctly this way by the general model.
        public var retriesRefusalsPlainly = true
        /// Ask the plain retry of the general model, which is slower but answered every
        /// refused file in testing; the content-tagging model refused 8 of 9 again.
        public var plainRetryUsesGeneralModel = true
        /// Leave the file name out when the file has at least this much text, so the
        /// AI judges the content and doesn't simply agree with the keyword voter,
        /// which already reads the name. `nil` always includes the name.
        public var hidesFileNameAboveTextLength: Int? = 200
        /// Show a photo to the general model, which can see images, when less
        /// than this much text could be read from it, such as a diagram or messy
        /// handwriting. In testing, looking took 5–10 s per photo against about
        /// 1.5 s for the text, and was no more accurate when the text was readable.
        /// `nil` never shows images.
        public var looksAtImagesBelowTextLength: Int? = 40

        public init() {}
    }

    static let unsorted = "Unsorted"
    private let model: SystemLanguageModel
    private let retryModel: SystemLanguageModel
    private let visionModel: SystemLanguageModel
    private let options: Options

    public init(options: Options = Options()) {
        // Sorting reads the student's own files, which can cover sensitive history and health topics.
        model = SystemLanguageModel(
            useCase: options.usesContentTagging ? .contentTagging : .general,
            guardrails: .permissiveContentTransformations
        )
        let general = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        retryModel = options.plainRetryUsesGeneralModel ? general : model
        visionModel = general
        self.options = options
    }

    /// Why the on-device model can't be used right now, or `nil` if it can.
    public var unavailableReason: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): String(localized: "This Mac can't run Apple Intelligence", bundle: .module)
        case .unavailable(.appleIntelligenceNotEnabled): String(localized: "Apple Intelligence is turned off", bundle: .module)
        case .unavailable(.modelNotReady): String(localized: "Apple Intelligence is still downloading", bundle: .module)
        case .unavailable: String(localized: "Apple Intelligence isn't available", bundle: .module)
        }
    }

    /// Loads the model ahead of the first file, so the first answer isn't slow.
    public func prewarm(for profile: Profile) {
        guard unavailableReason == nil else { return }
        LanguageModelSession(model: model, instructions: Self.instructions(for: profile)).prewarm()
    }

    public func vote(on evidence: Evidence, profile: Profile) async -> Vote {
        if let reason = unavailableReason {
            return .abstained(.model, .unavailable, reason)
        }
        let schema: GenerationSchema
        do {
            schema = try Self.schema(for: profile, asksForClues: options.asksForClues, asksForDocumentType: options.asksForDocumentType)
        } catch {
            return .abstained(.model, .failed, String(localized: "Couldn't prepare the question for the on-device AI", bundle: .module))
        }
        if let limit = options.looksAtImagesBelowTextLength, evidence.text.count < limit,
           let image = evidence.imageURL, visionModel.capabilities.contains(.vision) {
            let vote = await ask(about: evidence, showing: image, profile: profile, schema: schema)
            // If the picture can't be read, go on with the text read from it.
            if vote.abstention == nil { return vote }
        }
        let vote = await ask(about: evidence, profile: profile, schema: schema, excerptLength: options.excerptLength, retries: 1)
        guard vote.abstention?.kind == .declined, options.retriesRefusalsPlainly else { return vote }
        return await askPlainly(about: evidence, profile: profile)
    }

    /// The longest Folio waits for the model to look at a photo, and to answer
    /// about text. Answers normally take a few seconds.
    static let imageLimit: Duration = .seconds(90)
    static let textLimit: Duration = .seconds(60)

    /// Asks the general model, which can see images, about a photo and the text read from it.
    private func ask(about evidence: Evidence, showing image: URL, profile: Profile, schema: GenerationSchema) async -> Vote {
        let session = LanguageModelSession(model: visionModel, instructions: Self.instructions(for: profile))
        let text = prompt(for: evidence, excerptLength: options.excerptLength)
        let includesSchema = options.includesSchemaInPrompt
        do {
            let content = try await AIDeadline.run(within: Self.imageLimit) {
                try await session.respond(
                    to: Prompt {
                        text
                        Attachment(imageURL: image)
                    },
                    schema: schema,
                    includeSchemaInPrompt: includesSchema,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 60)
                ).content
            }
            return Self.vote(from: content, evidence: evidence, profile: profile, sawImage: true)
        } catch {
            return Self.abstention(for: error)
        }
    }

    /// How long Folio waits for the system's AI budget to come back before going on without it.
    static let longestWaitForRateLimit: Duration = .seconds(20)

    private func ask(about evidence: Evidence, profile: Profile, schema: GenerationSchema, excerptLength: Int, retries: Int, waitedForBudget: Bool = false) async -> Vote {
        // A new session per file keeps earlier files out of the model's limited context.
        let session = LanguageModelSession(model: model, instructions: Self.instructions(for: profile))
        let text = prompt(for: evidence, excerptLength: excerptLength)
        let includesSchema = options.includesSchemaInPrompt
        let tokens = options.asksForClues ? 160 : 60
        do {
            let content = try await AIDeadline.run(within: Self.textLimit) {
                try await session.respond(
                    to: text,
                    schema: schema,
                    includeSchemaInPrompt: includesSchema,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: tokens)
                ).content
            }
            return Self.vote(from: content, evidence: evidence, profile: profile)
        } catch LanguageModelError.contextSizeExceeded where retries > 0 {
            return await ask(about: evidence, profile: profile, schema: schema, excerptLength: excerptLength / 3, retries: retries - 1, waitedForBudget: waitedForBudget)
        } catch LanguageModelError.rateLimited(let limit) where !waitedForBudget {
            // macOS limits how much an app can use the model in a short time. Wait for it once.
            let wait = limit.resetDate.map { Duration.seconds(max(1, min($0.timeIntervalSinceNow, 20))) } ?? .seconds(3)
            try? await Task.sleep(for: min(wait, Self.longestWaitForRateLimit))
            return await ask(about: evidence, profile: profile, schema: schema, excerptLength: excerptLength, retries: retries, waitedForBudget: true)
        } catch {
            return Self.abstention(for: error)
        }
    }

    /// Asks for just the subject's name as plain text, then finds the first of the
    /// student's subjects named in the reply.
    private func askPlainly(about evidence: Evidence, profile: Profile) async -> Vote {
        let instructions = Self.instructions(for: profile) + "\nReply with only the subject's name, or \(Self.unsorted)."
        let session = LanguageModelSession(model: retryModel, instructions: instructions)
        let text = prompt(for: evidence, excerptLength: options.excerptLength)
        do {
            let reply = try await AIDeadline.run(within: Self.textLimit) {
                try await session.respond(to: text, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 20)).content
            }
            let answer = TermMatcher.normalize(reply)
            let named = profile.sortableSubjects.compactMap { subject -> (Subject, String.Index)? in
                answer.range(of: TermMatcher.normalize(subject.name)).map { (subject, $0.lowerBound) }
            }
            if let subject = named.min(by: { $0.1 < $1.1 })?.0 {
                return Vote(voter: .model, scores: [subject.id: 1], strength: 1, reasons: [String(localized: "On-device AI chose \(subject.name)", bundle: .module)])
            }
            if answer.contains(TermMatcher.normalize(Self.unsorted)) {
                return Vote(voter: .model, scores: [:], notSchoolwork: 1, reasons: [String(localized: "On-device AI: doesn't look like schoolwork", bundle: .module)])
            }
            return .abstained(.model, .failed, String(localized: "The on-device AI's answer wasn't one of your subjects", bundle: .module))
        } catch {
            return Self.abstention(for: error)
        }
    }

    private static func abstention(for error: any Error) -> Vote {
        let detail = String(describing: error)
        let declined = Vote.abstained(.model, .declined, String(localized: "The on-device AI declined to read this file", bundle: .module), detail: detail)
        switch error {
        case LanguageModelError.guardrailViolation, LanguageModelError.refusal:
            return declined
        case LanguageModelError.unsupportedLanguageOrLocale:
            return .abstained(.model, .failed, String(localized: "The on-device AI doesn't read this language yet", bundle: .module), detail: detail)
        case LanguageModelError.rateLimited:
            return .abstained(.model, .unavailable, String(localized: "The on-device AI is busy, so Folio went on without it", bundle: .module), detail: detail)
        case LanguageModelError.timeout, is AIDeadline.Exceeded:
            return .abstained(.model, .failed, String(localized: "The on-device AI took too long to answer", bundle: .module), detail: detail)
        default:
            // Errors from before macOS 27's LanguageModelError can still describe a refusal.
            let description = detail.lowercased()
            if description.contains("guardrail") || description.contains("refusal") { return declined }
            return .abstained(.model, .failed, String(localized: "The on-device AI couldn't answer", bundle: .module), detail: detail)
        }
    }

    // MARK: The question

    static func instructions(for profile: Profile) -> String {
        var lines = ["You sort a student's school files into the right subject folder. The student's subjects are:"]
        for subject in profile.sortableSubjects {
            lines.append(subject.summary.isEmpty ? "- \(subject.name)" : "- \(subject.name): \(subject.summary)")
        }
        lines.append("""
        Choose the one subject the file's content is about. Use the content first, because file names can be misleading. Files can be in any language.
        If the file is not schoolwork, such as a receipt, ticket or personal document, or you cannot tell, choose \(unsorted).
        Give the exam or document year only if the file states it.
        """)
        return lines.joined(separator: "\n")
    }

    private func prompt(for evidence: Evidence, excerptLength: Int) -> String {
        let hidesName = options.hidesFileNameAboveTextLength.map { evidence.text.count >= $0 } ?? false
        return Self.prompt(for: evidence, excerptLength: excerptLength, includesFileName: !hidesName)
    }

    static func prompt(for evidence: Evidence, excerptLength: Int, includesFileName: Bool = true) -> String {
        var lines: [String] = []
        if includesFileName { lines.append("File name: \(evidence.fileName)") }
        if let title = evidence.title { lines.append("Title: \(title)") }
        if let host = evidence.sourceHost { lines.append("Downloaded from: \(host)") }
        lines.append(evidence.text.isEmpty ? "Content: (no readable text)" : "Content:\n\(evidence.text.prefix(excerptLength))")
        return lines.joined(separator: "\n")
    }

    static func schema(for profile: Profile, asksForClues: Bool = false, asksForDocumentType: Bool = false) throws -> GenerationSchema {
        var properties: [DynamicGenerationSchema.Property] = []
        if asksForClues {
            properties.append(.init(name: "clues", description: "A few words from the file that show its subject", schema: DynamicGenerationSchema(type: String.self)))
        }
        properties.append(.init(name: "subject", schema: DynamicGenerationSchema(name: "Subject", anyOf: profile.sortableSubjects.map(\.name) + [unsorted])))
        if asksForDocumentType {
            let types = DynamicGenerationSchema(name: "DocumentType", anyOf: profile.documentTypes.map(\.name) + ["Other"])
            properties.append(.init(name: "documentType", schema: types))
        }
        properties.append(.init(name: "year", description: "The exam or document year, only if the file states it", schema: DynamicGenerationSchema(type: Int.self), isOptional: true))
        return try GenerationSchema(root: DynamicGenerationSchema(name: "FileClassification", properties: properties), dependencies: [])
    }

    static func vote(from content: GeneratedContent, evidence: Evidence, profile: Profile, sawImage: Bool = false) -> Vote {
        var facets = Facets()
        if let type = try? content.value(String.self, forProperty: "documentType"), type != "Other" {
            facets.documentType = type
        }
        // Keep a year only if the file actually mentions it: the model sometimes invents one.
        if let year = (try? content.value(Int?.self, forProperty: "year")) ?? nil,
           (evidence.fileName + " " + (evidence.title ?? "") + " " + evidence.text).contains(String(year)) {
            facets.year = year
        }
        let clues = ((try? content.value(String.self, forProperty: "clues")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard let name = try? content.value(String.self, forProperty: "subject"),
              name != unsorted,
              let subject = profile.subject(named: name)
        else {
            return Vote(voter: .model, scores: [:], notSchoolwork: 1, facets: facets, reasons: [String(localized: "On-device AI: doesn't look like schoolwork", bundle: .module)])
        }
        let reason = if !clues.isEmpty {
            String(localized: "On-device AI: \(String(clues.prefix(90)))", bundle: .module)
        } else if sawImage {
            String(localized: "On-device AI looked at the image and chose \(subject.name)", bundle: .module)
        } else {
            String(localized: "On-device AI chose \(subject.name)", bundle: .module)
        }
        return Vote(voter: .model, scores: [subject.id: 1], strength: 1, facets: facets, reasons: [reason])
    }
}
