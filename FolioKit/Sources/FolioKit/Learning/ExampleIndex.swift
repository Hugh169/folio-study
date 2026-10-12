import Foundation

/// Files the student has filed, kept as embeddings so new files can be
/// compared with them.
public struct ExampleIndex: Sendable {
    public struct Example: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var subjectID: Subject.ID
        /// The file's name, for the "Like …" reason.
        public var name: String
        public var embedding: TextEmbedder.Embedding

        public init(id: UUID = UUID(), subjectID: Subject.ID, name: String, embedding: TextEmbedder.Embedding) {
            self.id = id
            self.subjectID = subjectID
            self.name = name
            self.embedding = embedding
        }
    }

    /// How similar a file is to one subject's closest examples.
    public struct Match: Sendable {
        public var subjectID: Subject.ID
        public var similarity: Float
        public var nearest: Example
    }

    public private(set) var examples: [Example] = []
    /// The average vector for each model. Subtracting it before comparing makes
    /// differences between topics stand out: raw vectors of any two texts look
    /// alike (0.8–0.95), while centred ones are positive for the same subject
    /// and mostly negative for different ones.
    private var centres: [String: [Float]] = [:]

    public init(_ examples: [Example] = []) {
        self.examples = examples
        updateCentres()
    }

    public var count: Int { examples.count }

    public mutating func add(_ example: Example) {
        examples.append(example)
        updateCentres()
    }

    public mutating func removeAll(where shouldRemove: (Example) -> Bool) {
        examples.removeAll(where: shouldRemove)
        updateCentres()
    }

    /// Each subject's similarity to `embedding`: the average of its `neighbours`
    /// closest examples, best subject first.
    public func matches(for embedding: TextEmbedder.Embedding, neighbours: Int = 3, among subjects: Set<Subject.ID>) -> [Match] {
        guard let centre = centres[embedding.model] else { return [] }
        let query = Self.normalised(Self.subtract(centre, from: embedding.vector))
        var bySubject: [Subject.ID: [(Float, Example)]] = [:]
        for example in examples where example.embedding.model == embedding.model && subjects.contains(example.subjectID) {
            let vector = Self.normalised(Self.subtract(centre, from: example.embedding.vector))
            bySubject[example.subjectID, default: []].append((Self.dot(query, vector), example))
        }
        return bySubject.compactMap { subject, scored -> Match? in
            let closest = scored.sorted { $0.0 > $1.0 }.prefix(neighbours)
            guard let nearest = closest.first else { return nil }
            let average = closest.reduce(0) { $0 + $1.0 } / Float(closest.count)
            return Match(subjectID: subject, similarity: average, nearest: nearest.1)
        }
        .sorted { $0.similarity > $1.similarity }
    }

    private mutating func updateCentres() {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for example in examples {
            let model = example.embedding.model
            var sum = sums[model] ?? [Float](repeating: 0, count: example.embedding.vector.count)
            guard sum.count == example.embedding.vector.count else { continue }
            for index in sum.indices {
                sum[index] += example.embedding.vector[index]
            }
            sums[model] = sum
            counts[model, default: 0] += 1
        }
        centres = Dictionary(uniqueKeysWithValues: sums.map { model, sum in
            let count = Float(counts[model] ?? 1)
            return (model, sum.map { $0 / count })
        })
    }

    static func subtract(_ centre: [Float], from vector: [Float]) -> [Float] {
        guard centre.count == vector.count else { return vector }
        return zip(vector, centre).map { $0 - $1 }
    }

    static func normalised(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for index in a.indices {
            total += a[index] * b[index]
        }
        return total
    }
}
