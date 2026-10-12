import Foundation

/// Finds the student's files by what's in them. Rare words count for more than
/// common ones, as in a search engine, and a word matches its other endings
/// ("oxidation", "oxidised"). When files have embeddings, how alike their
/// meaning is to the search lifts files that say the same thing in other words.
///
/// Measured on the test set (`folio-eval --search`): searching file names put a
/// right file in the top five for 15% of searches, the words in files for 96%,
/// and meaning alone for 56%, so words lead and meaning only adds to them.
public struct LibrarySearch: Sendable {
    public struct Document: Sendable {
        public var id: UUID
        public var name: String
        public var text: String
        public var embedding: TextEmbedder.Embedding?

        public init(id: UUID, name: String, text: String, embedding: TextEmbedder.Embedding? = nil) {
            self.id = id
            self.name = name
            self.text = text
            self.embedding = embedding
        }
    }

    public struct Result: Hashable, Sendable {
        public var id: UUID
        /// About 0 to 1.3: the share of the search's weight found in the file,
        /// plus a little for meaning.
        public var score: Double
        /// The search's words found in the file.
        public var matched: [String]
    }

    public struct Settings: Sendable {
        /// How much meaning adds: its similarity, from −1 to 1, times this.
        public var meaningWeight = 0.3
        /// The least share of the search's weight a file needs to be shown.
        public var minimumWords = 0.4
        /// Files short of `minimumWords` are still shown when their meaning is at least this close.
        public var minimumMeaningWithSomeWords: Float = 0.45

        public init() {}
    }

    private var ids: [UUID] = []
    private var names: [String] = []
    private var wordSets: [Set<String>] = []
    /// Each word and the documents it's in.
    private var postings: [String: [Int]] = [:]
    private var meaning: MeaningIndex
    private var settings: Settings

    public init(_ documents: [Document], settings: Settings = Settings()) {
        self.settings = settings
        meaning = MeaningIndex(documents.compactMap { document in
            document.embedding.map { MeaningIndex.Item(id: document.id, embedding: $0) }
        })
        for (index, document) in documents.enumerated() {
            ids.append(document.id)
            names.append(document.name)
            let words = Set(Self.words(document.name + "\n" + document.text))
            wordSets.append(words)
            for word in words {
                postings[word, default: []].append(index)
            }
        }
    }

    public var count: Int { ids.count }

    /// Words that don't help find anything.
    static let stopWords: Set<String> = CardCheck.stopWords.union(["about", "notes", "file", "files", "my", "on", "in", "of", "to", "a", "an", "is", "it", "do", "does", "did", "make", "up", "his", "her", "out"])

    static func words(_ text: String) -> [String] {
        CardCheck.words(text)
    }

    /// The files that match `query` best, first. `queryEmbedding` is the
    /// search's embedding, made with the same model as the files'.
    public func search(_ query: String, queryEmbedding: TextEmbedder.Embedding? = nil, limit: Int = 20) -> [Result] {
        let wanted = Array(Set(Self.words(query).filter { !Self.stopWords.contains($0) && ($0.count >= 2 || $0.contains(where: \.isNumber)) }))
        guard !wanted.isEmpty else { return [] }
        let total = Double(ids.count)
        var weights: [String: Double] = [:]
        var holders: [String: Set<Int>] = [:]
        for word in wanted {
            let documents = documents(matching: word)
            holders[word] = documents
            // Rarer words weigh more; a word in every file still counts a little.
            weights[word] = log((total + 1) / (Double(documents.count) + 0.5)) + 0.1
        }
        // Words in none of the files can't tell them apart, so only the others count.
        let totalWeight = wanted.filter { !(holders[$0] ?? []).isEmpty }.reduce(0) { $0 + (weights[$1] ?? 0) }
        guard totalWeight > 0 else { return [] }
        var scores: [Int: Double] = [:]
        var matched: [Int: [String]] = [:]
        for word in wanted {
            for document in holders[word] ?? [] {
                scores[document, default: 0] += (weights[word] ?? 0) / totalWeight
                matched[document, default: []].append(word)
            }
        }
        var similarity: [UUID: Float] = [:]
        if let queryEmbedding, meaning.count > 0 {
            for match in meaning.matches(for: queryEmbedding, limit: ids.count, minimumSimilarity: -1) {
                similarity[match.id] = match.similarity
            }
        }
        return scores.compactMap { document, share -> Result? in
            let alike = similarity[ids[document]] ?? 0
            guard share >= settings.minimumWords || (share > 0 && alike >= settings.minimumMeaningWithSomeWords) else { return nil }
            return Result(id: ids[document], score: share + settings.meaningWeight * Double(alike), matched: matched[document] ?? [])
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    /// Files most like the file `id`: sharing its rarer words, and close in meaning.
    public func related(to id: UUID, limit: Int = 5) -> [Result] {
        guard let index = ids.firstIndex(of: id) else { return [] }
        let total = Double(ids.count)
        let weight = { (word: String) in log((total + 1) / (Double(postings[word]?.count ?? 0) + 0.5)) }
        // Only words that say what a file is about count, weighted by how rare they are.
        let isTelling = { (word: String) in word.count >= 3 && !Self.stopWords.contains(word) }
        let length = { (words: Set<String>) in words.filter(isTelling).reduce(0) { $0 + pow(weight($1), 2) }.squareRoot() }
        let own = wordSets[index].filter(isTelling)
        let ownLength = length(own)
        var shared: [Int: Double] = [:]
        for word in own {
            let w = weight(word)
            for other in postings[word] ?? [] where other != index {
                shared[other, default: 0] += w * w
            }
        }
        let alike = Dictionary(uniqueKeysWithValues: meaning.related(to: id, limit: ids.count, minimumSimilarity: -1).map { ($0.id, $0.similarity) })
        return shared.map { other, dot -> Result in
            let otherLength = length(wordSets[other])
            let cosine = ownLength > 0 && otherLength > 0 ? dot / (ownLength * otherLength) : 0
            return Result(id: ids[other], score: cosine + settings.meaningWeight * Double(alike[ids[other]] ?? 0), matched: [])
        }
        .filter { $0.score > 0.05 }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    /// The documents holding the word, or the same word with another ending.
    private func documents(matching word: String) -> Set<Int> {
        var found = Set(postings[word] ?? [])
        if word.count >= 3 {
            for (other, documents) in postings where other != word && Self.isForm(other, of: word) {
                found.formUnion(documents)
            }
        }
        return found
    }

    /// The same word with another ending: a plural, "-ed" or "-ing", or a long
    /// word that differs only in its last three letters ("differentiate",
    /// "differentiation"), but not another word that starts the same way
    /// ("different", "differentiation"; "plants", "plantation").
    static func isForm(_ word: String, of other: String) -> Bool {
        let (short, long) = word.count <= other.count ? (word, other) : (other, word)
        if short.count >= 3, long.hasPrefix(short), ["s", "es", "d", "ed", "ing", "er", "ers", "ly"].contains(String(long.dropFirst(short.count))) {
            return true
        }
        guard short.count >= 7 else { return false }
        return zip(short, long).prefix { $0 == $1 }.count >= long.count - 3
    }
}
