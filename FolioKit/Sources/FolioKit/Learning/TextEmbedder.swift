import Foundation
import NaturalLanguage

/// Turns text into a list of numbers that captures what it's about, using
/// Apple's on-device contextual embedding. Files on similar topics get similar
/// numbers. The Latin-script model reads English, French, Spanish and about 17
/// other languages; other scripts use their own models.
public actor TextEmbedder {
    public struct Embedding: Hashable, Codable, Sendable {
        public var vector: [Float]
        /// The model that made it. Vectors from different models can't be compared.
        public var model: String

        public init(vector: [Float], model: String) {
            self.vector = vector
            self.model = model
        }
    }

    /// The model reads at most 256 tokens, which is roughly this much text.
    static let maxCharacters = 1200

    private var models: [String: NLContextualEmbedding] = [:]
    private var unavailable: Set<String> = []

    public init() {}

    /// The meaning of the start of `text`, or `nil` if this Mac doesn't have the model.
    public func embed(_ text: String, language: String? = nil) async -> Embedding? {
        let excerpt = String(text.prefix(Self.maxCharacters))
        guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let model = await model(for: language),
              let result = try? model.embeddingResult(for: excerpt, language: language.map(NLLanguage.init(rawValue:)))
        else { return nil }

        // Average the vectors of every token into one vector for the whole text.
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: excerpt.startIndex..<excerpt.endIndex) { vector, _ in
            for index in vector.indices where index < sum.count {
                sum[index] += vector[index]
            }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return Embedding(vector: sum.map { Float($0 / Double(count)) }, model: model.modelIdentifier)
    }

    /// Whether the model for Latin-script languages is on this Mac and loads.
    public var isAvailable: Bool {
        get async { await model(for: nil) != nil }
    }

    private func model(for language: String?) async -> NLContextualEmbedding? {
        let key = language ?? "latin"
        if let model = models[key] { return model }
        guard !unavailable.contains(key) else { return nil }

        let candidate = language.flatMap { NLContextualEmbedding(language: NLLanguage(rawValue: $0)) }
            ?? NLContextualEmbedding(script: .latin)
        guard let candidate else {
            unavailable.insert(key)
            return nil
        }
        if let loaded = models.values.first(where: { $0.modelIdentifier == candidate.modelIdentifier }) {
            models[key] = loaded
            return loaded
        }
        if !candidate.hasAvailableAssets {
            // Downloads the model the first time; macOS keeps it afterwards.
            let result = await withCheckedContinuation { continuation in
                candidate.requestAssets { result, _ in continuation.resume(returning: result) }
            }
            guard result == .available else {
                unavailable.insert(key)
                return nil
            }
        }
        do {
            try candidate.load()
        } catch {
            unavailable.insert(key)
            return nil
        }
        models[key] = candidate
        return candidate
    }
}
