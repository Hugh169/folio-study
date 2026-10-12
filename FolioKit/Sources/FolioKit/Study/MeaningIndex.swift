import Foundation

/// Finds the student's files by what they're about rather than by name. What
/// the student types, and each file, are compared by the embeddings Folio
/// already keeps for sorting, after taking away what all the files have in
/// common, as `ExampleIndex` does: raw vectors of any two texts look alike.
public struct MeaningIndex: Sendable {
    public struct Item: Hashable, Sendable {
        public var id: UUID
        public var embedding: TextEmbedder.Embedding

        public init(id: UUID, embedding: TextEmbedder.Embedding) {
            self.id = id
            self.embedding = embedding
        }
    }

    public struct Match: Hashable, Sendable {
        public var id: UUID
        /// From −1 to 1. Files on the same topic are usually above 0.3.
        public var similarity: Float
    }

    /// Each file's vector, centred and normalised, with its model.
    private var vectors: [(id: UUID, model: String, vector: [Float])] = []
    private var centres: [String: [Float]] = [:]

    public init(_ items: [Item]) {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for item in items {
            let model = item.embedding.model
            var sum = sums[model] ?? [Float](repeating: 0, count: item.embedding.vector.count)
            guard sum.count == item.embedding.vector.count else { continue }
            for index in sum.indices {
                sum[index] += item.embedding.vector[index]
            }
            sums[model] = sum
            counts[model, default: 0] += 1
        }
        for (model, sum) in sums {
            let count = Float(counts[model] ?? 1)
            centres[model] = sum.map { $0 / count }
        }
        vectors = items.compactMap { item in
            guard let centre = centres[item.embedding.model], centre.count == item.embedding.vector.count else { return nil }
            return (item.id, item.embedding.model, ExampleIndex.normalised(ExampleIndex.subtract(centre, from: item.embedding.vector)))
        }
    }

    public var count: Int { vectors.count }

    /// Files most like `query`, best first.
    public func matches(for query: TextEmbedder.Embedding, limit: Int = 10, minimumSimilarity: Float = 0.2) -> [Match] {
        guard let centre = centres[query.model], centre.count == query.vector.count else { return [] }
        let wanted = ExampleIndex.normalised(ExampleIndex.subtract(centre, from: query.vector))
        return ranked(against: wanted, model: query.model, excluding: nil, limit: limit, minimumSimilarity: minimumSimilarity)
    }

    /// Files most like the file `id`, best first, leaving out the file itself.
    public func related(to id: UUID, limit: Int = 5, minimumSimilarity: Float = 0.3) -> [Match] {
        guard let entry = vectors.first(where: { $0.id == id }) else { return [] }
        return ranked(against: entry.vector, model: entry.model, excluding: id, limit: limit, minimumSimilarity: minimumSimilarity)
    }

    private func ranked(against wanted: [Float], model: String, excluding: UUID?, limit: Int, minimumSimilarity: Float) -> [Match] {
        vectors
            .filter { $0.model == model && $0.id != excluding }
            .map { Match(id: $0.id, similarity: ExampleIndex.dot(wanted, $0.vector)) }
            .filter { $0.similarity >= minimumSimilarity }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0 }
    }
}
