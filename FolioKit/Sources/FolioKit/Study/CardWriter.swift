import Foundation
import FoundationModels

/// Writes flashcards from the student's own notes with Apple's on-device
/// model, a part of the notes at a time. Every card goes through `CardCheck`:
/// cards whose answers aren't in the notes are dropped, and so are repeats.
///
/// Folio never gives it a task sheet, so it never writes answers to an
/// assessment; it only helps the student learn what's in their own files.
public actor CardWriter {
    public struct Options: Sendable {
        /// About how many characters of the notes the model reads at once. In
        /// testing, 900 gave a third more cards than 1,200 for a fifth more time.
        public var partLength = 900
        /// The most parts read from one file, so a long file doesn't take
        /// minutes. A longer file's parts are spread through all of it.
        public var maxParts = 10
        public var maxCards = 24

        public init() {}
    }

    /// The cards written from one file, and what was dropped.
    public struct Result: Sendable {
        public var drafts: [CardDraft] = []
        public var partsRead = 0
        public var partsDeclined = 0
        /// Cards dropped because their answers weren't in the notes.
        public var notInNotes = 0
        public var repeats = 0
        /// Cards that didn't make sense as cards, such as a question about the notes themselves.
        public var malformed = 0
        /// Why there are no cards, when there aren't any.
        public var problem: StudyAIProblem?
    }

    private let model: SystemLanguageModel
    private let options: Options

    public init(options: Options = Options()) {
        model = StudyAI.model()
        self.options = options
    }

    /// Why the on-device model can't write cards right now, or `nil` if it can.
    public var unavailableReason: String? {
        StudyAI.unavailableReason(model)
    }

    static let instructions = """
        You write flashcards that help a student revise their own notes.
        Ask about the key facts, terms, definitions, formulas, causes and effects in the notes.
        Every answer must be stated in the notes. Keep each answer short but complete: a phrase or one sentence that fully answers the question.
        Never ask about the notes themselves, such as their title, page numbers or who wrote them.
        Write the questions and answers in the same language as the notes.
        """

    /// Writes cards from `text`, the whole of a file's text. `progress`
    /// hears how many parts are done out of how many.
    public func cards(from text: String, subject: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Result {
        var result = Result()
        if let reason = unavailableReason {
            result.problem = .unavailable(reason)
            return result
        }
        guard text.filter(\.isLetter).count >= 80 else {
            result.problem = .tooLittleText
            return result
        }
        let parts = CardCheck.parts(of: text, length: options.partLength, maxParts: options.maxParts)
        for (index, part) in parts.enumerated() {
            guard !Task.isCancelled, result.drafts.count < options.maxCards else { break }
            progress?(index, parts.count)
            do {
                let drafts = try await write(from: part, subject: subject, splitsLeft: 1, waitedForBudget: false)
                result.partsRead += 1
                let sorted = CardCheck.sort(drafts, notes: part, existing: result.drafts)
                result.drafts += sorted.kept.prefix(options.maxCards - result.drafts.count)
                result.notInNotes += sorted.notInNotes
                result.repeats += sorted.repeats
                result.malformed += sorted.malformed
            } catch StudyAIProblem.declined {
                result.partsRead += 1
                result.partsDeclined += 1
            } catch let problem as StudyAIProblem {
                result.problem = problem
                break
            } catch {
                result.problem = .failed(error.localizedDescription)
                break
            }
        }
        progress?(parts.count, parts.count)
        if result.drafts.isEmpty && result.problem == nil {
            result.problem = result.partsDeclined > 0 && result.partsDeclined == result.partsRead ? .declined : nil
        }
        return result
    }

    /// Whether the text is mostly questions, such as an exam paper or a
    /// worksheet. Cards from those are poor: the answers aren't in them.
    public static func looksLikeQuestions(_ text: String) -> Bool {
        CardCheck.looksLikeQuestions(text)
    }

    /// Asks the model for cards from one part. A part that's too long for the
    /// model is halved and each half asked about.
    private func write(from part: String, subject: String, splitsLeft: Int, waitedForBudget: Bool) async throws -> [CardDraft] {
        // A new session for each part keeps earlier parts out of the model's limited context.
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let prompt = "Subject: \(subject)\nNotes:\n\(part)"
        do {
            let cards = try await AIDeadline.run(within: StudyAI.answerLimit) {
                try await session.respond(
                    to: prompt,
                    generating: GeneratedCards.self,
                    includeSchemaInPrompt: true,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600)
                ).content.cards.map { CardDraft(question: $0.question, answer: $0.answer) }
            }
            return cards
        } catch {
            switch StudyAI.failure(for: error) {
            case .declined:
                // Asked again for plain text, the model declined far less often in
                // testing, as it did for sorting sensitive history.
                return try await writePlainly(from: part, subject: subject)
            case .tooLong where splitsLeft > 0:
                let halves = CardCheck.parts(of: part, length: max(part.count / 2, 200), maxParts: 2)
                var drafts: [CardDraft] = []
                for half in halves {
                    drafts += try await write(from: half, subject: subject, splitsLeft: splitsLeft - 1, waitedForBudget: waitedForBudget)
                }
                return drafts
            case .tooLong:
                throw StudyAIProblem.failed(error.localizedDescription)
            case .rateLimited(let wait) where !waitedForBudget:
                // macOS limits how much an app can use the model in a short time. Wait for it once.
                try? await Task.sleep(for: wait)
                return try await write(from: part, subject: subject, splitsLeft: splitsLeft, waitedForBudget: true)
            case .rateLimited:
                throw StudyAIProblem.unavailable(String(localized: "The on-device AI is busy. Try again in a minute.", bundle: .module))
            case .unsupportedLanguage:
                throw StudyAIProblem.unsupportedLanguage
            case .tooSlow:
                throw StudyAIProblem.failed(String(localized: "The on-device AI took too long to answer", bundle: .module))
            case .other(let detail):
                throw StudyAIProblem.failed(detail)
            }
        }
    }
}

extension CardWriter {
    /// Asks for cards as plain text, "Q: … A: …", after the model declined to
    /// answer in the structured form.
    private func writePlainly(from part: String, subject: String) async throws -> [CardDraft] {
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let prompt = "Subject: \(subject)\nNotes:\n\(part)\n\nWrite up to four flashcards from these notes. Write each card on two lines: \"Q: \" and the question, then \"A: \" and the answer."
        do {
            let reply = try await AIDeadline.run(within: StudyAI.answerLimit) {
                try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600)).content
            }
            return Self.plainCards(in: reply)
        } catch {
            switch StudyAI.failure(for: error) {
            case .declined: throw StudyAIProblem.declined
            case .unsupportedLanguage: throw StudyAIProblem.unsupportedLanguage
            default: throw StudyAIProblem.failed(error.localizedDescription)
            }
        }
    }

    /// The cards in a plain-text reply: each "Q:" line with the "A:" line after it.
    static func plainCards(in reply: String) -> [CardDraft] {
        var drafts: [CardDraft] = []
        var question: String?
        for line in reply.split(separator: "\n") {
            // Leave out list markers and bold, such as "1. **Q:**".
            let cleaned = line.replacing("**", with: "").trimmingCharacters(in: .whitespaces)
                .replacing(/^(?:[-•*]|\d{1,2}[.)])\s*/, with: "")
            if let match = cleaned.firstMatch(of: /^(?i)(?:q|question)\s*\d*\s*[:.]\s*(.+)$/) {
                question = String(match.1)
            } else if let match = cleaned.firstMatch(of: /^(?i)(?:a|answer)\s*\d*\s*[:.]\s*(.+)$/), let asked = question {
                drafts.append(CardDraft(question: asked, answer: String(match.1)))
                question = nil
            }
        }
        return drafts
    }
}

@Generable(description: "Flashcards for revising the notes")
struct GeneratedCards {
    @Guide(description: "Cards about the most important facts, terms and ideas in the notes", .count(1...4))
    var cards: [GeneratedCard]
}

@Generable
struct GeneratedCard {
    @Guide(description: "A question that the notes answer")
    var question: String
    @Guide(description: "The answer, from the notes: a phrase or one sentence that fully answers the question")
    var answer: String
}
