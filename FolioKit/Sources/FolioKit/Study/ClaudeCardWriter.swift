import Foundation

/// Writes flashcards with Claude Haiku, with the student's own key, when they
/// choose Claude for a file. Claude reads all of the file, a part at a time,
/// and writes a card for each important idea in it. There's no limit on how
/// many: the student's own Anthropic account pays, about a fifth of a US cent
/// a part. Claude quotes the sentence each answer comes from, and its cards go
/// through the same checks as the on-device AI's.
public struct ClaudeCardWriter: Sendable {
    /// About how many characters of the notes Claude reads in one request:
    /// around 3,000 tokens, few enough that the cards for them fit in `maxTokens`.
    public static let partLength = 12_000
    /// How many parts Claude reads at once, so a long file is quick without
    /// running into a new Anthropic account's rate limits.
    static let partsAtOnce = 3
    static let maxTokens = 8192
    /// The most of the student's existing questions sent with each part, so
    /// Claude writes different ones. Every repeat is dropped anyway.
    static let avoidedCharacters = 8_000

    public struct Result: Sendable {
        public var drafts: [CardDraft] = []
        public var notInNotes = 0
        public var repeats = 0
        public var malformed = 0
        public var partsRead = 0
        /// Parts Claude declined to read, or answered in a way Folio couldn't read.
        public var partsSkipped = 0
        /// Why there are no cards, or why Claude stopped before the end of the
        /// file. Cards from the parts it read are still in `drafts`.
        public var problem: ClaudeVoter.Problem?
    }

    /// What came back for one part of the notes.
    struct PartReply: Sendable {
        var sorted = CardCheck.Sorted()
        var problem: ClaudeVoter.Problem?
    }

    private let key: String
    private let ledger: ClaudeUsageLedger?
    private let session: URLSession

    public init(key: String, ledger: ClaudeUsageLedger? = nil, session: URLSession = .shared) {
        self.key = key
        self.ledger = ledger
        self.session = session
    }

    /// Writes cards from `text`, the whole of a file's text. `avoiding` are
    /// cards the student already has from it: Claude is asked for different
    /// ones, and repeats are dropped. `progress` hears how many parts are done
    /// out of how many.
    public func cards(from text: String, subject: String, avoiding: [CardDraft] = [], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Result {
        let parts = CardCheck.parts(of: text, length: Self.partLength, maxParts: 0)
        let questions = Self.questions(toAvoid: avoiding)
        var replies: [Int: PartReply] = [:]
        progress?(0, parts.count)
        await withTaskGroup(of: (Int, PartReply).self) { group in
            var next = 0
            var stopped = false
            while next < min(Self.partsAtOnce, parts.count) {
                let index = next
                group.addTask { (index, await write(parts[index], subject: subject, avoiding: questions)) }
                next += 1
            }
            for await (index, reply) in group {
                replies[index] = reply
                progress?(replies.count, parts.count)
                // A wrong key, no credit or no connection would stop every part, so stop asking.
                if let problem = reply.problem, !problem.isAboutOneFile { stopped = true }
                if !stopped, !Task.isCancelled, next < parts.count {
                    let index = next
                    group.addTask { (index, await write(parts[index], subject: subject, avoiding: questions)) }
                    next += 1
                }
            }
        }

        var result = Result()
        for index in replies.keys.sorted() {
            guard let reply = replies[index] else { continue }
            if let problem = reply.problem {
                if problem.isAboutOneFile {
                    result.partsSkipped += 1
                } else {
                    result.problem = result.problem ?? problem
                }
                continue
            }
            result.partsRead += 1
            result.notInNotes += reply.sorted.notInNotes
            result.malformed += reply.sorted.malformed
            result.repeats += reply.sorted.repeats
            // Parts are checked on their own, so drop repeats of cards from other parts, and of the student's own.
            for draft in reply.sorted.kept {
                if CardCheck.isRepeat(draft, of: avoiding + result.drafts) {
                    result.repeats += 1
                } else {
                    result.drafts.append(draft)
                }
            }
        }
        if result.drafts.isEmpty, result.problem == nil, result.partsSkipped > 0 {
            result.problem = replies.values.compactMap(\.problem).first
        }
        return result
    }

    /// The student's questions to send with each part, most recent first, up to `avoidedCharacters`.
    static func questions(toAvoid cards: [CardDraft]) -> [String] {
        var questions: [String] = []
        var length = 0
        for question in cards.reversed().map(\.question) {
            length += question.count + 3
            guard length <= avoidedCharacters else { break }
            questions.append(question)
        }
        return questions
    }

    /// Asks Claude for cards from one part. An answer cut short at `maxTokens`
    /// had more to say than fits, so the part is halved and each half asked about.
    private func write(_ part: String, subject: String, avoiding questions: [String], splitsLeft: Int = 1) async -> PartReply {
        let body: Data
        do {
            body = try Self.requestBody(for: part, subject: subject, avoiding: questions)
        } catch {
            return PartReply(problem: .malformed)
        }
        let response: ClaudeAPI.Response
        do {
            // Writing dozens of cards takes longer than choosing a subject.
            response = try await ClaudeAPI.send(body, key: key, session: session, retries: 3, timeout: 180)
        } catch {
            return PartReply(problem: .offline)
        }
        let reply = Self.reply(to: response.data, status: response.status, notes: part)
        if let usage = reply.usage {
            ledger?.record(inputTokens: usage.input, outputTokens: usage.output)
        }
        guard reply.wasCutShort, splitsLeft > 0 else { return reply.part }
        var halves = PartReply()
        for half in CardCheck.parts(of: part, length: part.count / 2 + 200, maxParts: 0) {
            let answer = await write(half, subject: subject, avoiding: questions, splitsLeft: splitsLeft - 1)
            if let problem = answer.problem, !problem.isAboutOneFile { return answer }
            halves.sorted.kept += answer.sorted.kept
            halves.sorted.notInNotes += answer.sorted.notInNotes
            halves.sorted.malformed += answer.sorted.malformed
            halves.sorted.repeats += answer.sorted.repeats
            if answer.problem != nil, halves.problem == nil { halves.problem = answer.problem }
        }
        // Cards from either half make the part a success.
        if !halves.sorted.kept.isEmpty { halves.problem = nil }
        return halves
    }

    static func requestBody(for notes: String, subject: String, avoiding questions: [String] = []) throws -> Data {
        let card: [String: Any] = [
            "type": "object",
            "properties": [
                "question": ["type": "string"],
                "answer": ["type": "string"],
                "quote": ["type": "string", "description": "The sentence from the notes that gives the answer, copied exactly"],
            ],
            "required": ["question", "answer", "quote"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["cards": ["type": "array", "items": card]],
            "required": ["cards"],
            "additionalProperties": false,
        ]
        var message = "Subject: \(subject)\nNotes:\n\(notes)"
        if !questions.isEmpty {
            message += "\n\nThe student already has cards asking these questions, so write different ones:\n" + questions.map { "- \($0)" }.joined(separator: "\n")
        }
        let body: [String: Any] = [
            "model": ClaudeVoter.model,
            "max_tokens": maxTokens,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "system": CardWriter.instructions + "\nWrite a card for each important fact, term, definition, formula, date, cause and effect in the notes, so the cards cover all of them, with the most important first.",
            "messages": [["role": "user", "content": [["type": "text", "text": message]]]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Claude's answer for one part: its cards that pass the checks, what went
    /// wrong if anything, the tokens used, and whether the answer was cut short.
    static func reply(to data: Data, status: Int, notes: String) -> (part: PartReply, usage: (input: Int, output: Int)?, wasCutShort: Bool) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            return (PartReply(problem: ClaudeAPI.problem(status: status, json: json).0), nil, false)
        }
        guard let json else { return (PartReply(problem: .malformed), nil, false) }
        let usage = ClaudeAPI.usage(in: json)
        switch json["stop_reason"] as? String {
        case "refusal":
            return (PartReply(problem: .refused), usage, false)
        case "max_tokens":
            return (PartReply(problem: .malformed), usage, true)
        default:
            break
        }
        guard let text = ClaudeAPI.text(in: json),
              let answer = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let cards = answer["cards"] as? [[String: Any]]
        else {
            return (PartReply(problem: .malformed), usage, false)
        }
        let folded = TermMatcher.normalize(notes)
        let drafts = cards.compactMap { card -> CardDraft? in
            guard let question = card["question"] as? String, let answer = card["answer"] as? String else { return nil }
            // Keep Claude's quote only if it really is in the notes; otherwise Folio finds one.
            let quote = (card["quote"] as? String).flatMap { folded.contains(TermMatcher.normalize($0)) ? $0 : nil }
            return CardDraft(question: question, answer: answer, quote: quote)
        }
        return (PartReply(sorted: CardCheck.sort(drafts, notes: notes, existing: [])), usage, false)
    }
}
