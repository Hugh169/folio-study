import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Asks Claude Haiku, with the student's own API key, about files the other
/// voters left for review. It reads what the on-device AI reads: up to 1,500
/// characters of a file's text, its title and the website it came from, and
/// its name when there's little text. It sees a photo only when the student
/// allowed that and almost no text could be read from the photo.
///
/// Swift has no official Anthropic SDK, so this sends the Messages API's JSON
/// over HTTPS, in the shapes Anthropic documents: the answer is held to a JSON
/// schema with `output_config.format`, and low effort keeps thinking short.
public actor ClaudeVoter: Voter {
    public nonisolated let kind = VoterKind.cloud

    public static let model = "claude-haiku-5-5"

    public struct Options: Sendable {
        /// How many characters of the file's text Claude reads.
        public var excerptLength = 1500
        /// Leave the file name out when there's at least this much text, as the on-device AI does.
        public var hidesFileNameAboveTextLength = 200
        /// Show Claude a photo when less than this much text could be read from
        /// it. `nil`, the default, never sends photos.
        public var sendsPhotosBelowTextLength: Int?

        public init() {}
    }

    /// Why Claude couldn't help.
    public enum Problem: Error, Hashable, Sendable {
        /// The key is wrong, revoked or expired.
        case badKey
        /// The Anthropic account needs credit or a payment method, in Anthropic's words.
        case billing(String)
        /// Too many requests, or the account reached a limit.
        case rateLimited
        /// Anthropic turned the request down, in its words.
        case rejected(String)
        /// Anthropic's servers are busy or had a problem.
        case unavailable(String)
        /// Folio couldn't connect to Anthropic.
        case offline
        /// Claude declined to read the file.
        case refused
        /// Claude's answer couldn't be read.
        case malformed

        /// In words for Settings.
        public var message: String {
            switch self {
            case .badKey: String(localized: "Claude didn't accept this key. Check it in the Claude Console, or paste a new one.", bundle: .module)
            case .billing(let reason): reason.isEmpty ? String(localized: "Your Anthropic account needs credit or a payment method.", bundle: .module) : reason
            case .rateLimited: String(localized: "Claude is busy, or your account reached a limit. Folio will try again with the next file.", bundle: .module)
            case .rejected(let reason): String(localized: "Claude turned the request down: \(reason)", bundle: .module)
            case .unavailable(let reason): String(localized: "Claude couldn't answer: \(reason)", bundle: .module)
            case .offline: String(localized: "Couldn't reach Claude. Check your internet connection.", bundle: .module)
            case .refused: String(localized: "Claude declined to read a file.", bundle: .module)
            case .malformed: String(localized: "Claude's answer couldn't be read.", bundle: .module)
            }
        }

        /// A problem with one file, rather than with the key or the connection.
        public var isAboutOneFile: Bool {
            self == .refused || self == .malformed
        }

        /// Problems every request would hit again until the student fixes them.
        var stopsAsking: Bool {
            switch self {
            case .badKey, .billing: true
            default: false
            }
        }
    }

    /// What came back from one request.
    struct Reply: Sendable {
        var vote: Vote
        var problem: Problem?
        var usage: (input: Int, output: Int)?
    }

    private let key: String
    private let options: Options
    private let session: URLSession
    private let ledger: ClaudeUsageLedger?
    private let onAnswer: (@Sendable (Problem?) -> Void)?
    /// Set after a problem that every request would hit again, such as a wrong key.
    private var stopped: Problem?

    /// - Parameter onAnswer: Hears how each request went: `nil` when Claude answered.
    public init(
        key: String,
        options: Options = Options(),
        ledger: ClaudeUsageLedger? = nil,
        session: URLSession = .shared,
        onAnswer: (@Sendable (Problem?) -> Void)? = nil
    ) {
        self.key = key
        self.options = options
        self.ledger = ledger
        self.session = session
        self.onAnswer = onAnswer
    }

    public func vote(on evidence: Evidence, profile: Profile) async -> Vote {
        if let stopped {
            return .abstained(.cloud, .unavailable, stopped.message)
        }
        let reply = await ask(about: evidence, profile: profile)
        if let usage = reply.usage {
            ledger?.record(inputTokens: usage.input, outputTokens: usage.output)
        }
        if let problem = reply.problem, problem.stopsAsking {
            stopped = problem
        }
        onAnswer?(reply.problem)
        return reply.vote
    }

    /// Checks a key with a short question. Returns `nil` when Claude answered.
    public static func test(key: String, session: URLSession = .shared) async -> Problem? {
        let probe = Evidence(fileName: "Worksheet.txt", contentType: "public.plain-text", text: "Differentiate y = 3x² + 2x with respect to x.")
        var profile = Profile.starter()
        profile.subjects = [Subject(name: "Mathematics", colorHex: 0x0A84FF), Subject(name: "English", colorHex: 0xFF9F0A)]
        return await ClaudeVoter(key: key, session: session).ask(about: probe, profile: profile).problem
    }

    private func ask(about evidence: Evidence, profile: Profile) async -> Reply {
        let body: Data
        do {
            body = try Self.requestBody(for: evidence, profile: profile, options: options, image: Self.photo(for: evidence, options: options))
        } catch {
            return Reply(vote: .abstained(.cloud, .failed, String(localized: "Couldn't prepare the question for Claude", bundle: .module), detail: String(describing: error)), problem: .malformed)
        }
        return await send(body, evidence: evidence, profile: profile, retries: 1)
    }

    private func send(_ body: Data, evidence: Evidence, profile: Profile, retries: Int) async -> Reply {
        do {
            let response = try await ClaudeAPI.send(body, key: key, session: session, retries: retries)
            return Self.reply(to: response.data, status: response.status, evidence: evidence, profile: profile)
        } catch {
            return Reply(vote: .abstained(.cloud, .unavailable, String(localized: "Couldn't reach Claude", bundle: .module), detail: error.localizedDescription), problem: .offline)
        }
    }

    // MARK: The question

    static func requestBody(for evidence: Evidence, profile: Profile, options: Options = Options(), image: Data? = nil) throws -> Data {
        var content: [[String: Any]] = []
        // Anthropic recommends putting an image before the question about it.
        if let image {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()],
            ])
        }
        let includesName = evidence.text.count < options.hidesFileNameAboveTextLength
        content.append(["type": "text", "text": ModelVoter.prompt(for: evidence, excerptLength: options.excerptLength, includesFileName: includesName)])

        var names: [String] = []
        for name in profile.sortableSubjects.map(\.name) + [ModelVoter.unsorted]
        where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "subject": ["type": "string", "enum": names],
                "year": ["type": "integer", "description": "The exam or document year, only if the file states it"],
            ],
            "required": ["subject"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": model,
            // Room for a little thinking before the short answer.
            "max_tokens": 1024,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "system": ModelVoter.instructions(for: profile),
            "messages": [["role": "user", "content": content]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The photo to show Claude, if the student allowed photos and hardly any text could be read from this one.
    static func photo(for evidence: Evidence, options: Options) -> Data? {
        guard let limit = options.sendsPhotosBelowTextLength, evidence.text.count < limit, let url = evidence.imageURL else { return nil }
        return jpeg(from: url)
    }

    /// The image as a JPEG at most 1,568 pixels on its long edge, which keeps
    /// the request small and costs Claude at most about 2,400 tokens to look at.
    static func jpeg(from url: URL, longEdge: Int = 1568) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longEdge,
              ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: The answer

    static func reply(to data: Data, status: Int, evidence: Evidence, profile: Profile) -> Reply {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let (problem, message) = ClaudeAPI.problem(status: status, json: json)
            return Reply(vote: .abstained(.cloud, .unavailable, problem.message, detail: "HTTP \(status): \(message)"), problem: problem)
        }
        guard let json else {
            return Reply(vote: .abstained(.cloud, .failed, String(localized: "Claude's answer couldn't be read", bundle: .module)), problem: .malformed)
        }
        let usage = ClaudeAPI.usage(in: json)

        switch json["stop_reason"] as? String {
        case "refusal":
            let category = (json["stop_details"] as? [String: Any])?["category"] as? String
            return Reply(vote: .abstained(.cloud, .declined, String(localized: "Claude declined to read this file", bundle: .module), detail: category), problem: .refused, usage: usage)
        case "max_tokens":
            return Reply(vote: .abstained(.cloud, .failed, String(localized: "Claude's answer was cut short", bundle: .module)), problem: .malformed, usage: usage)
        default:
            break
        }
        guard let text = ClaudeAPI.text(in: json),
              let answer = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let name = answer["subject"] as? String
        else {
            return Reply(vote: .abstained(.cloud, .failed, String(localized: "Claude's answer couldn't be read", bundle: .module)), problem: .malformed, usage: usage)
        }

        var facets = Facets()
        // Keep a year only if the file mentions it, as for the on-device AI.
        if let year = answer["year"] as? Int,
           (evidence.fileName + " " + (evidence.title ?? "") + " " + evidence.text).contains(String(year)) {
            facets.year = year
        }
        if name.caseInsensitiveCompare(ModelVoter.unsorted) == .orderedSame {
            return Reply(vote: Vote(voter: .cloud, scores: [:], notSchoolwork: 1, facets: facets, reasons: [String(localized: "Claude: doesn't look like schoolwork", bundle: .module)]), usage: usage)
        }
        guard let subject = profile.subject(named: name) else {
            return Reply(vote: .abstained(.cloud, .failed, String(localized: "Claude's answer wasn't one of your subjects", bundle: .module), detail: name), problem: .malformed, usage: usage)
        }
        return Reply(vote: Vote(voter: .cloud, scores: [subject.id: 1], strength: 1, facets: facets, reasons: [String(localized: "Claude chose \(subject.name)", bundle: .module)]), usage: usage)
    }
}

/// Counts Claude requests and tokens by month, so Settings can show roughly
/// what they cost: US$0.10 per million input tokens and US$0.50 per million
/// output tokens for Claude Haiku 5.5, for prompts under 100,000 tokens.
public final class ClaudeUsageLedger: @unchecked Sendable {
    public struct Usage: Hashable, Sendable {
        public var requests = 0
        public var inputTokens = 0
        public var outputTokens = 0

        public init(requests: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
            self.requests = requests
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        /// In US dollars.
        public var cost: Double {
            Double(inputTokens) * 0.10 / 1_000_000 + Double(outputTokens) * 0.50 / 1_000_000
        }
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func record(inputTokens: Int, outputTokens: Int, at date: Date = .now) {
        lock.withLock {
            let key = Self.key(for: date)
            var counts = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
            counts["requests", default: 0] += 1
            counts["input", default: 0] += inputTokens
            counts["output", default: 0] += outputTokens
            defaults.set(counts, forKey: key)
        }
    }

    /// The requests made in the month containing `date`.
    public func usage(in date: Date = .now) -> Usage {
        lock.withLock {
            let counts = defaults.dictionary(forKey: Self.key(for: date)) as? [String: Int] ?? [:]
            return Usage(requests: counts["requests"] ?? 0, inputTokens: counts["input"] ?? 0, outputTokens: counts["output"] ?? 0)
        }
    }

    private static func key(for date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "claudeUsage-%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
