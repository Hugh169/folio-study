import Foundation

/// A flashcard before the student keeps it.
public struct CardDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var question: String
    public var answer: String
    /// The line of the notes that gives the answer.
    public var quote: String?

    public init(id: UUID = UUID(), question: String, answer: String, quote: String? = nil) {
        self.id = id
        self.question = question
        self.answer = answer
        self.quote = quote
    }
}

/// The checks every written card goes through, whoever wrote it: its answer
/// has to be in the notes, it has to make sense as a card, and it mustn't
/// repeat one already kept. Also splits notes into parts the model can read.
enum CardCheck {
    /// What happened to the drafts from one part of the notes.
    struct Sorted {
        var kept: [CardDraft] = []
        var notInNotes = 0
        var repeats = 0
        var malformed = 0
    }

    /// Keeps the drafts that pass every check, adding each kept card's quote.
    /// `existing` are cards already kept from earlier parts.
    static func sort(_ drafts: [CardDraft], notes: String, existing: [CardDraft]) -> Sorted {
        var sorted = Sorted()
        let noteWords = Set(words(notes))
        for var draft in drafts {
            draft.question = plain(draft.question).trimmingCharacters(in: .whitespacesAndNewlines)
            draft.answer = plain(draft.answer).trimmingCharacters(in: .whitespacesAndNewlines)
            draft.quote = draft.quote.map(plain)
            guard isWellFormed(draft) else {
                sorted.malformed += 1
                continue
            }
            guard isGrounded(draft.answer, in: notes, noteWords: noteWords) else {
                sorted.notInNotes += 1
                continue
            }
            guard !isRepeat(draft, of: existing + sorted.kept) else {
                sorted.repeats += 1
                continue
            }
            if draft.quote == nil || draft.quote?.isEmpty == true {
                draft.quote = quote(for: draft, in: notes)
            }
            sorted.kept.append(draft)
        }
        return sorted
    }

    /// The text without the Markdown emphasis models sometimes add, so
    /// "*Nineteen Eighty-Four*" and "**key term**" read as plain words. Only
    /// asterisks that wrap words go, so "2*x*y" and "3 * 4" are kept.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<![\p{L}\p{N}*])(\*{1,3})(?=\S)(.+?)(?<=\S)\1(?![\p{L}\p{N}*])"#,
            with: "$2",
            options: .regularExpression
        )
    }

    // MARK: Answers in the notes

    /// Words that carry no meaning of their own, left out when checking that
    /// an answer comes from the notes.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "are", "was", "were", "been", "its", "this", "that", "these", "those", "from",
        "which", "who", "what", "when", "where", "how", "why", "than", "then", "into", "their", "they", "them",
        "there", "has", "have", "had", "not", "can", "will", "would", "should", "could", "also", "but", "such",
        "each", "all", "any", "one", "two", "more", "most", "less", "les", "des", "une", "est", "dans", "pour",
        "par", "sur", "qui", "que", "los", "las", "una", "por", "para", "con", "del", "die", "der", "das", "und",
        "ist", "ein", "eine", "mit", "von",
    ]

    /// The text's words, in lower case without accents.
    static func words(_ text: String) -> [String] {
        TermMatcher.normalize(text).split { !$0.isWordCharacter }.map(String.init)
    }

    /// Whether the notes give the answer: every number in it, and most of its
    /// other words, allowing for different endings ("electron", "electrons").
    /// Chinese, Japanese and Korean are compared a character at a time.
    static func isGrounded(_ answer: String, in notes: String, noteWords: Set<String>? = nil) -> Bool {
        let unspaced = answer.filter(\.isUnspacedScript)
        if unspaced.count >= 2 {
            let present = unspaced.filter { notes.contains($0) }.count
            return Double(present) / Double(unspaced.count) >= 0.8
        }
        let noteWords = noteWords ?? Set(words(notes))
        let all = words(answer)
        let content = all.filter { word in
            word.contains(where: \.isNumber) || (word.count >= 3 && !stopWords.contains(word))
        }
        // A short answer such as "F = ma" or "pH": all of it must be there.
        guard !content.isEmpty else {
            return !all.isEmpty && all.allSatisfy(noteWords.contains)
        }
        var found = 0
        for word in content {
            if word.contains(where: \.isNumber) {
                guard noteWords.contains(word) else { return false }
                found += 1
            } else if noteWords.contains(word) || noteWords.contains(where: { sharesStem($0, word) }) {
                found += 1
            }
        }
        return Double(found) / Double(content.count) >= 0.6
    }

    /// The same word with a different ending, such as "oxidation" and "oxidised".
    static func sharesStem(_ a: String, _ b: String) -> Bool {
        guard a.count >= 5, b.count >= 5 else { return false }
        let common = zip(a, b).prefix { $0 == $1 }.count
        return common >= max(5, min(a.count, b.count) - 3)
    }

    /// The sentence of the notes that gives the answer: the one sharing the
    /// most of the answer's words, then of the question's.
    static func quote(for draft: CardDraft, in notes: String) -> String? {
        let meaningful = { (text: String) in
            Set(words(text).filter { ($0.count >= 2 && !stopWords.contains($0)) || $0.contains(where: \.isNumber) })
        }
        let answer = meaningful(draft.answer)
        let question = meaningful(draft.question).subtracting(answer)
        guard !answer.isEmpty else { return nil }
        func count(_ wanted: Set<String>, in sentence: Set<String>) -> Int {
            wanted.filter { word in sentence.contains(word) || sentence.contains { sharesStem($0, word) } }.count
        }
        var best: (sentence: String, score: Int)?
        for sentence in sentences(of: notes) {
            let found = meaningful(sentence)
            let answered = count(answer, in: found)
            guard answered > 0 else { continue }
            let score = answered * 2 + count(question, in: found)
            if score > best?.score ?? 0 { best = (sentence, score) }
        }
        guard let best else { return nil }
        return best.sentence.count > 240 ? String(best.sentence.prefix(237)) + "…" : best.sentence
    }

    // MARK: Making sense

    /// Phrases that show a question is about the notes, not what they teach.
    private static let aboutTheNotes = ["these notes", "the notes", "this document", "the document", "this file", "the passage"]

    static func isWellFormed(_ draft: CardDraft) -> Bool {
        let question = draft.question
        let answer = draft.answer
        guard (6...260).contains(question.count), (1...320).contains(answer.count) else { return false }
        guard TermMatcher.normalize(question) != TermMatcher.normalize(answer) else { return false }
        let lower = question.lowercased()
        guard !aboutTheNotes.contains(where: { lower.contains($0) }) else { return false }
        // An answer that mostly repeats the question, as from an exam question with no answer in the text.
        let answerWords = Set(words(answer).filter { $0.count >= 3 && !stopWords.contains($0) })
        let questionWords = Set(words(question))
        return answerWords.count < 2 || Double(answerWords.intersection(questionWords).count) / Double(answerWords.count) < 0.6
    }

    /// Whether the text is mostly questions, such as an exam paper or a
    /// worksheet, which has few answers to make cards from.
    static func looksLikeQuestions(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 8 }
        guard lines.count >= 3 else { return false }
        let numbered = /^(?:question\s*\d+|q\d+\b|\(?\d{1,2}[.)]\s|\(?[a-h]\)\s)/
        let marks = /\(\s*\d+\s*marks?\s*\)/
        let questions = lines.filter { line in
            let lower = line.lowercased()
            return lower.firstMatch(of: numbered) != nil || lower.firstMatch(of: marks) != nil || line.hasSuffix("?")
        }
        return Double(questions.count) / Double(lines.count) >= 0.4
    }

    /// Asks the same thing as a card already kept.
    static func isRepeat(_ draft: CardDraft, of kept: [CardDraft]) -> Bool {
        let question = Set(words(draft.question))
        let answer = TermMatcher.normalize(draft.answer)
        return kept.contains { other in
            let otherQuestion = Set(words(other.question))
            let union = question.union(otherQuestion).count
            let overlap = union == 0 ? 1 : Double(question.intersection(otherQuestion).count) / Double(union)
            return overlap >= 0.75 || (overlap >= 0.4 && TermMatcher.normalize(other.answer) == answer)
        }
    }

    // MARK: Parts

    /// The notes in parts of about `length` characters, split between lines
    /// or sentences rather than inside them. A long file's parts are spread
    /// through all of it, rather than only its start.
    static func parts(of text: String, length: Int, maxParts: Int) -> [String] {
        var pieces: [String] = []
        for line in text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.count <= length {
                pieces.append(line)
            } else {
                pieces += pack(sentences(of: line).flatMap { split($0, length: length) }, length: length, separator: " ")
            }
        }
        var parts = pack(pieces, length: length, separator: "\n")
        // A short last part joins the one before rather than standing alone.
        if parts.count >= 2, let last = parts.last, last.count < length / 3, parts[parts.count - 2].count + last.count < length * 3 / 2 {
            parts.removeLast()
            parts[parts.count - 1] += "\n" + last
        }
        guard parts.count > maxParts, maxParts > 0 else { return parts }
        return (0..<maxParts).map { index in
            parts[maxParts == 1 ? 0 : index * (parts.count - 1) / (maxParts - 1)]
        }
    }

    /// Joins pieces in order into strings of at most `length` characters.
    private static func pack(_ pieces: [String], length: Int, separator: String) -> [String] {
        var packed: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + separator.count + piece.count <= length {
                current += separator + piece
            } else {
                packed.append(current)
                current = piece
            }
        }
        if !current.isEmpty { packed.append(current) }
        return packed
    }

    /// The text's sentences. A full stop only ends one before a space or a
    /// new line, so "pH 8.2" stays whole; Chinese and Japanese full stops always do.
    static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        func finish() {
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            current = ""
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == "\n" {
                finish()
                continue
            }
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if "。！？".contains(character) || (".!?".contains(character) && (next == nil || next?.isWhitespace == true)) {
                finish()
            }
        }
        finish()
        return sentences
    }

    /// A sentence longer than `length` cut between words.
    private static func split(_ sentence: String, length: Int) -> [String] {
        guard sentence.count > length else { return [sentence] }
        return pack(sentence.split(separator: " ").map(String.init), length: length, separator: " ")
    }
}
