import Foundation

/// Writes flashcards with Claude Haiku, with the student's own key, when they
/// choose Claude for a file. Claude reads up to `maxCharacters` of the file's
/// text in one request, quotes the sentence each answer comes from, and its
/// cards go through the same checks as the on-device AI's.
public struct ClaudeCardWriter: Sendable {
    /// About 6,000 tokens, which costs Claude Haiku well under a US cent with the answer.
    public static let maxCharacters = 24_000
    public static let maxCards = 24

    public struct Result: Sendable {
        public var drafts: [CardDraft] = []
        public var notInNotes = 0
        public var repeats = 0
        public var malformed = 0
        /// Why there are no cards, when there aren't any.
        public var problem: ClaudeVoter.Problem?
    }

    private let key: String
    private let ledger: ClaudeUsageLedger?
    private let session: URLSession

    public init(key: String, ledger: ClaudeUsageLedger? = nil, session: URLSession = .shared) {
        self.key = key
        self.ledger = ledger
        self.session = session
    }

    public func cards(from text: String, subject: String) async -> Result {
        let excerpt = String(text.prefix(Self.maxCharacters))
        let body: Data
        do {
            body = try Self.requestBody(for: excerpt, subject: subject)
        } catch {
            return Result(problem: .malformed)
        }
        let response: ClaudeAPI.Response
        do {
            // Writing two dozen cards takes longer than choosing a subject.
            response = try await ClaudeAPI.send(body, key: key, session: session, timeout: 120)
        } catch {
            return Result(problem: .offline)
        }
        let reply = Self.reply(to: response.data, status: response.status, notes: excerpt)
        if let usage = reply.usage {
            ledger?.record(inputTokens: usage.input, outputTokens: usage.output)
        }
        return reply.result
    }

    static func requestBody(for notes: String, subject: String) throws -> Data {
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
        let body: [String: Any] = [
            "model": ClaudeVoter.model,
            "max_tokens": 4096,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "system": CardWriter.instructions + "\nWrite up to \(maxCards) cards, covering all of the notes, with the most important ideas first.",
            "messages": [["role": "user", "content": [["type": "text", "text": "Subject: \(subject)\nNotes:\n\(notes)"]]]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func reply(to data: Data, status: Int, notes: String) -> (result: Result, usage: (input: Int, output: Int)?) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            return (Result(problem: ClaudeAPI.problem(status: status, json: json).0), nil)
        }
        guard let json else { return (Result(problem: .malformed), nil) }
        let usage = ClaudeAPI.usage(in: json)
        if json["stop_reason"] as? String == "refusal" {
            return (Result(problem: .refused), usage)
        }
        guard let text = ClaudeAPI.text(in: json),
              let answer = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let cards = answer["cards"] as? [[String: Any]]
        else {
            return (Result(problem: .malformed), usage)
        }
        let folded = TermMatcher.normalize(notes)
        let drafts = cards.compactMap { card -> CardDraft? in
            guard let question = card["question"] as? String, let answer = card["answer"] as? String else { return nil }
            // Keep Claude's quote only if it really is in the notes; otherwise Folio finds one.
            let quote = (card["quote"] as? String).flatMap { folded.contains(TermMatcher.normalize($0)) ? $0 : nil }
            return CardDraft(question: question, answer: answer, quote: quote)
        }
        let sorted = CardCheck.sort(drafts, notes: notes, existing: [])
        var result = Result(drafts: Array(sorted.kept.prefix(maxCards)), notInNotes: sorted.notInNotes, repeats: sorted.repeats, malformed: sorted.malformed)
        if result.drafts.isEmpty && cards.isEmpty { result.problem = .malformed }
        return (result, usage)
    }
}
