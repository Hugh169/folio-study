import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FolioKit
import FolioTestSupport

/// Answers requests to Claude from canned responses, so tests never use the
/// network. Each test uses its own API key, which picks its responses.
final class CannedClaude: URLProtocol {
    struct Response: Sendable {
        var status = 200
        var body: String
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: [String: [Response]] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// A session whose requests with `key` get `responses` in order. When
    /// they run out, requests fail as if the Mac were offline.
    static func session(key: String, responses: [Response]) -> URLSession {
        lock.withLock { waiting[key] = responses }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedClaude.self]
        return URLSession(configuration: configuration)
    }

    static func requestCount(for key: String) -> Int {
        lock.withLock { counts[key] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "x-api-key") ?? ""
        let next: Response? = Self.lock.withLock {
            Self.counts[key, default: 0] += 1
            guard var list = Self.waiting[key], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            Self.waiting[key] = list
            return first
        }
        guard let next, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A message from Claude, with a thinking block before the answer as Haiku 5.5 sends.
    static func message(_ text: String?, stopReason: String = "end_turn", extra: [String: Any] = [:]) -> String {
        var content: [[String: Any]] = [["type": "thinking", "thinking": "", "signature": "EqQBCkYIBhgC"]]
        if let text { content.append(["type": "text", "text": text]) }
        var body: [String: Any] = [
            "id": "msg_01", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
            "content": content, "stop_reason": stopReason,
            "usage": ["input_tokens": 812, "output_tokens": 24],
        ]
        body.merge(extra) { $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    static func error(_ type: String, _ message: String) -> String {
        #"{"type": "error", "error": {"type": "\#(type)", "message": "\#(message)"}, "request_id": "req_01"}"#
    }
}

/// Collects what a voter reports after each request.
final class HeardProblems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClaudeVoter.Problem?] = []

    func add(_ problem: ClaudeVoter.Problem?) { lock.withLock { items.append(problem) } }
    var all: [ClaudeVoter.Problem?] { lock.withLock { items } }
}

/// A voter that always gives the same answer and counts how often it's asked.
actor FixedVoter: Voter {
    nonisolated let kind: VoterKind
    let answer: Vote
    private(set) var askedCount = 0

    init(_ answer: Vote) {
        kind = answer.voter
        self.answer = answer
    }

    func vote(on evidence: Evidence, profile: Profile) async -> Vote {
        askedCount += 1
        return answer
    }
}

struct ClaudeVoterTests {
    let profile: Profile = {
        var profile = Profile.starter()
        profile.subjects.append(Subject(name: "Legal Studies", colorHex: 0x8E8E93, isArchived: true))
        return profile
    }()
    var chemistry: Subject { profile.subject(named: "Chemistry")! }
    let report = Evidence(
        fileName: "Untitled 3.pdf",
        contentType: "com.adobe.pdf",
        title: "Prac report",
        text: String(repeating: "Titrate the acid with sodium hydroxide from the burette and record the volume at the end point. ", count: 30),
        sourceURLs: ["https://www.example.edu.au/prac.pdf"]
    )

    func body(_ evidence: Evidence, options: ClaudeVoter.Options = .init(), image: Data? = nil) throws -> [String: Any] {
        let data = try ClaudeVoter.requestBody(for: evidence, profile: profile, options: options, image: image)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func content(of body: [String: Any]) throws -> [[String: Any]] {
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        return try #require(messages.first?["content"] as? [[String: Any]])
    }

    func reply(_ status: Int, _ body: String, about evidence: Evidence? = nil) -> ClaudeVoter.Reply {
        ClaudeVoter.reply(to: Data(body.utf8), status: status, evidence: evidence ?? report, profile: profile)
    }

    // MARK: The question

    @Test func theQuestionFollowsAnthropicsShape() throws {
        let body = try body(report)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == 1024)
        // Thinking stays on Haiku's default; low effort keeps it short.
        #expect(body["thinking"] == nil)
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "low")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["subject"])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(properties["subject"]?["enum"] as? [String] == profile.sortableSubjects.map(\.name) + ["Unsorted"])
        #expect(properties["year"]?["type"] as? String == "integer")
        #expect((body["system"] as? String)?.contains("- Chemistry") == true)
        #expect((body["system"] as? String)?.contains("Legal Studies") == false)
    }

    @Test func claudeReadsWhatTheOnDeviceAIReads() throws {
        let blocks = try content(of: body(report))
        #expect(blocks.map { $0["type"] as? String } == ["text"])
        let text = try #require(blocks.first?["text"] as? String)
        // Plenty of text, so the name is left out, and only the first 1,500 characters go.
        #expect(!text.contains("Untitled 3.pdf"))
        #expect(text.contains("Title: Prac report"))
        #expect(text.contains("Downloaded from: www.example.edu.au"))
        #expect(text.count < 1600)

        let note = Evidence(fileName: "Cell labels.pdf", contentType: "com.adobe.pdf", text: "nucleus, mitochondria")
        let short = try #require(content(of: body(note)).first?["text"] as? String)
        #expect(short.contains("File name: Cell labels.pdf"))
    }

    @Test func photosGoOnlyWhenAllowedAndComeFirst() throws {
        let temp = try TemporaryFolder()
        let url = temp.url.appending(path: "IMG_2041.png")
        try DocumentRenderer.writeMoleculeDiagram(to: url)
        let photo = Evidence(fileName: "IMG_2041.png", contentType: "public.png", imageURL: url)

        #expect(ClaudeVoter.photo(for: photo, options: ClaudeVoter.Options()) == nil)
        var options = ClaudeVoter.Options()
        options.sendsPhotosBelowTextLength = 40
        let jpeg = try #require(ClaudeVoter.photo(for: photo, options: options))

        let blocks = try content(of: body(photo, options: options, image: jpeg))
        #expect(blocks.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(blocks.first?["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect((source["data"] as? String).flatMap { Data(base64Encoded: $0) } == jpeg)

        let readable = Evidence(fileName: "IMG_2042.png", contentType: "public.png", text: String(repeating: "Label the parts of the cell. ", count: 3), imageURL: url)
        #expect(ClaudeVoter.photo(for: readable, options: options) == nil)
    }

    @Test func bigPhotosAreMadeSmaller() throws {
        let temp = try TemporaryFolder()
        let url = temp.url.appending(path: "big.png")
        let context = try #require(CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let jpeg = try #require(ClaudeVoter.jpeg(from: url))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1568)
        #expect((properties[kCGImagePropertyPixelHeight] as? Int).map { abs($0 - 1045) <= 1 } == true)
    }

    // MARK: The answer

    @Test func aChosenSubjectBecomesAVote() {
        // Anthropic says enum values can come back in a different case.
        let reply = reply(200, CannedClaude.message(#"{"subject": "chemistry"}"#))
        #expect(reply.problem == nil)
        #expect(reply.vote.abstention == nil)
        #expect(reply.vote.top?.id == chemistry.id)
        #expect(reply.vote.reasons == ["Claude chose Chemistry"])
        #expect(reply.usage?.input == 812)
        #expect(reply.usage?.output == 24)
    }

    @Test func unsortedMeansNotSchoolwork() {
        let reply = reply(200, CannedClaude.message(#"{"subject": "Unsorted"}"#))
        #expect(reply.problem == nil)
        #expect(reply.vote.abstention == nil)
        #expect(reply.vote.top == nil)
        #expect(reply.vote.notSchoolwork == 1)
    }

    @Test func aYearIsKeptOnlyWhenTheFileMentionsIt() {
        let paper = Evidence(fileName: "Chemistry exam.pdf", contentType: "com.adobe.pdf", text: "2024 Higher School Certificate Examination. Chemistry.")
        #expect(reply(200, CannedClaude.message(#"{"subject": "Chemistry", "year": 2024}"#), about: paper).vote.facets.year == 2024)
        #expect(reply(200, CannedClaude.message(#"{"subject": "Chemistry", "year": 1953}"#), about: paper).vote.facets.year == nil)
    }

    @Test func refusalsAndUnreadableAnswersAreAbstentions() {
        let refused = reply(200, CannedClaude.message(nil, stopReason: "refusal", extra: ["stop_details": ["category": "general_harms"]]))
        #expect(refused.problem == .refused)
        #expect(refused.vote.abstention?.kind == .declined)
        #expect(refused.vote.abstention?.detail == "general_harms")
        #expect(refused.usage != nil)

        let cutShort = reply(200, CannedClaude.message(#"{"subj"#, stopReason: "max_tokens"))
        #expect(cutShort.problem == .malformed)
        #expect(cutShort.vote.abstention?.kind == .failed)

        #expect(reply(200, CannedClaude.message("Chemistry")).problem == .malformed)
        #expect(reply(200, CannedClaude.message(#"{"subject": "Legal Studies"}"#)).problem == .malformed)
        #expect(reply(200, "<html>Bad gateway</html>").problem == .malformed)
    }

    @Test func errorsBecomeProblemsForSettings() {
        #expect(reply(401, CannedClaude.error("authentication_error", "invalid x-api-key")).problem == .badKey)
        #expect(reply(402, CannedClaude.error("billing_error", "Add a payment method.")).problem == .billing("Add a payment method."))
        let credit = "Your credit balance is too low to access the Anthropic API."
        #expect(reply(400, CannedClaude.error("invalid_request_error", credit)).problem == .billing(credit))
        let image = "messages.0.content.0.image.source.base64: The image could not be processed."
        #expect(reply(400, CannedClaude.error("invalid_request_error", image)).problem == .rejected(image))
        #expect(reply(429, CannedClaude.error("rate_limit_error", "Rate limited")).problem == .rateLimited)
        #expect(reply(529, CannedClaude.error("overloaded_error", "Overloaded")).problem == .unavailable("Overloaded"))
        #expect(reply(502, "<html>Bad gateway</html>").problem == .unavailable("HTTP 502"))
        for status in [400, 401, 429, 529] {
            #expect(reply(status, "{}").vote.abstention?.kind == .unavailable)
        }
        #expect(ClaudeVoter.Problem.refused.isAboutOneFile)
        #expect(!ClaudeVoter.Problem.badKey.isAboutOneFile)
    }

    // MARK: Asking

    @Test func eachAnswerIsCountedAndReported() async throws {
        let key = "sk-ant-test-\(UUID().uuidString)"
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = ClaudeUsageLedger(defaults: defaults)
        let heard = HeardProblems()
        let session = CannedClaude.session(key: key, responses: [.init(body: CannedClaude.message(#"{"subject": "Chemistry"}"#))])
        let voter = ClaudeVoter(key: key, ledger: ledger, session: session) { heard.add($0) }

        let vote = await voter.vote(on: report, profile: profile)

        #expect(vote.top?.id == chemistry.id)
        #expect(heard.all == [nil])
        #expect(ledger.usage() == ClaudeUsageLedger.Usage(requests: 1, inputTokens: 812, outputTokens: 24))
    }

    @Test func aWrongKeyStopsFurtherQuestions() async {
        let key = "sk-ant-test-\(UUID().uuidString)"
        let heard = HeardProblems()
        let session = CannedClaude.session(key: key, responses: [.init(status: 401, body: CannedClaude.error("authentication_error", "invalid x-api-key"))])
        let voter = ClaudeVoter(key: key, session: session) { heard.add($0) }

        let first = await voter.vote(on: report, profile: profile)
        let second = await voter.vote(on: report, profile: profile)

        #expect(first.abstention?.kind == .unavailable)
        #expect(second.abstention?.reason == ClaudeVoter.Problem.badKey.message)
        #expect(CannedClaude.requestCount(for: key) == 1)
        #expect(heard.all == [.badKey])
    }

    @Test func aBusyServerIsAskedOnceMore() async {
        let key = "sk-ant-test-\(UUID().uuidString)"
        let session = CannedClaude.session(key: key, responses: [
            .init(status: 529, body: CannedClaude.error("overloaded_error", "Overloaded"), headers: ["retry-after": "1"]),
            .init(body: CannedClaude.message(#"{"subject": "Chemistry"}"#)),
        ])
        let vote = await ClaudeVoter(key: key, session: session).vote(on: report, profile: profile)
        #expect(vote.top?.id == chemistry.id)
        #expect(CannedClaude.requestCount(for: key) == 2)
    }

    @Test func beingOfflineIsQuiet() async {
        let key = "sk-ant-test-\(UUID().uuidString)"
        let heard = HeardProblems()
        let voter = ClaudeVoter(key: key, session: CannedClaude.session(key: key, responses: [])) { heard.add($0) }
        let vote = await voter.vote(on: report, profile: profile)
        #expect(vote.abstention?.kind == .unavailable)
        #expect(heard.all == [.offline])
    }

    @Test func testingAKey() async {
        let good = "sk-ant-test-\(UUID().uuidString)"
        let goodSession = CannedClaude.session(key: good, responses: [.init(body: CannedClaude.message(#"{"subject": "Mathematics"}"#))])
        #expect(await ClaudeVoter.test(key: good, session: goodSession) == nil)

        let bad = "sk-ant-test-\(UUID().uuidString)"
        let badSession = CannedClaude.session(key: bad, responses: [.init(status: 401, body: CannedClaude.error("authentication_error", "invalid x-api-key"))])
        #expect(await ClaudeVoter.test(key: bad, session: badSession) == .badKey)
    }
}

struct ClaudeUsageTests {
    @Test func usageIsCountedByMonth() throws {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = ClaudeUsageLedger(defaults: defaults)
        let calendar = Calendar(identifier: .gregorian)
        let october = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)))
        let november = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))

        ledger.record(inputTokens: 600_000, outputTokens: 100_000, at: october)
        ledger.record(inputTokens: 400_000, outputTokens: 100_000, at: october)
        ledger.record(inputTokens: 1_000, outputTokens: 10, at: november)

        let usage = ledger.usage(in: october)
        #expect(usage.requests == 2)
        #expect(usage.inputTokens == 1_000_000)
        // US$0.10 for a million tokens in, and US$0.50 a million out.
        #expect(abs(usage.cost - 0.20) < 0.000_001)
        #expect(ledger.usage(in: november).requests == 1)
    }
}

struct SecondOpinionTests {
    let profile = Profile.starter()
    var chemistry: Subject.ID { profile.subject(named: "Chemistry")!.id }
    var physics: Subject.ID { profile.subject(named: "Physics")!.id }
    let file = Evidence(fileName: "notes.pdf", contentType: "com.adobe.pdf")

    var keywords: Vote { Vote(voter: .keywords, scores: [chemistry: 0.6, physics: 0.4], strength: 4, reasons: ["Found “titration”"]) }
    var model: Vote { Vote(voter: .model, scores: [physics: 1], strength: 1, reasons: ["On-device AI chose Physics"]) }
    var claude: Vote { Vote(voter: .cloud, scores: [chemistry: 1], strength: 1, reasons: ["Claude chose Chemistry"]) }

    @Test func claudeTakesTheOnDeviceAIsPlace() {
        let arbiter = Arbiter(level: .careful)
        #expect(arbiter.decide([keywords, model], evidence: file, profile: profile).outcome == .review)

        let votes = Classifier.votes([keywords, model], adding: claude)
        #expect(votes.map(\.voter) == [.keywords, .cloud])
        let decision = arbiter.decide(votes, evidence: file, profile: profile)
        #expect(decision.outcome == .file(chemistry))
        #expect(decision.reasons.contains("Claude chose Chemistry"))
    }

    @Test func claudeAloneCantFileAFile() {
        // Nothing in the file's words points anywhere, so Claude's choice is only offered.
        let declined = Vote.abstained(.model, .declined, "The on-device AI declined to read this file")
        let votes = Classifier.votes([declined], adding: claude)
        for level in [AutoFileLevel.careful, .balanced] {
            let decision = Arbiter(level: level).decide(votes, evidence: file, profile: profile)
            #expect(decision.outcome == .review)
            #expect(decision.suggestions == [chemistry])
        }
    }

    @Test func whenClaudeDoesntAnswerTheVotesStay() {
        let votes = Classifier.votes([keywords, model], adding: .abstained(.cloud, .unavailable, "Couldn't reach Claude"))
        #expect(votes.map(\.voter) == [.keywords, .model, .cloud])
        let decision = Arbiter(level: .careful).decide(votes, evidence: file, profile: profile)
        #expect(decision.outcome == .review)
        #expect(decision.suggestions == [physics, chemistry])
    }

    func analysis(from pipeline: SortingPipeline) async -> SortingPipeline.Analysis? {
        for await event in pipeline.events {
            switch event {
            case .analysed(_, let analysis): return analysis
            case .failed, .duplicate: return nil
            case .progress: continue
            }
        }
        return nil
    }

    @Test(.timeLimit(.minutes(1))) func thePipelineAsksClaudeAboutFilesLeftForReview() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Downloads/notes.txt", contents: "Fill the burette and record the volume.")
        let asked = FixedVoter(claude)
        let pipeline = SortingPipeline(classifier: Classifier(voters: [FixedVoter(keywords)]), secondOpinion: asked, profile: profile)

        await pipeline.enqueue([.init(url: file)])
        let analysis = try #require(await analysis(from: pipeline))

        #expect(analysis.decision.outcome == .file(chemistry))
        #expect(analysis.decision.votes.map(\.voter) == [.keywords, .cloud])
        #expect(await asked.askedCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func filesAlreadyDecidedAreNotSent() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Downloads/MATH1131 week 3.txt", contents: "Questions for this week.")
        let asked = FixedVoter(claude)
        let rule = Vote(voter: .rules, scores: [physics: 1], strength: 1, reasons: ["Your rule"])
        let pipeline = SortingPipeline(classifier: Classifier(voters: [FixedVoter(rule), FixedVoter(keywords)]), secondOpinion: asked, profile: profile)

        await pipeline.enqueue([.init(url: file)])
        let analysis = try #require(await analysis(from: pipeline))

        #expect(analysis.decision.outcome == .file(physics))
        #expect(await asked.askedCount == 0)
    }
}
