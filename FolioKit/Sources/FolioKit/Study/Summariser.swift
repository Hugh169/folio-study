import Foundation
import FoundationModels

/// Says in a few points what one of the student's files is about, with Apple's
/// on-device model, for "What's this?". It reads as much of the file's text as
/// fits in the model's context: the start of a long file.
public actor Summariser {
    private let model: SystemLanguageModel

    public init() {
        model = StudyAI.model()
    }

    /// Why the on-device model can't summarise right now, or `nil` if it can.
    public var unavailableReason: String? {
        StudyAI.unavailableReason(model)
    }

    static let instructions = """
        You help a student see quickly what one of their school files is about.
        Summarise the file's content in two to five short points, in the same language as the file.
        Say what it covers and its main ideas, not how it is laid out.
        """

    /// The file's main points, or why there aren't any.
    public func summary(of text: String, title: String? = nil) async -> Result<[String], StudyAIProblem> {
        if let reason = unavailableReason { return .failure(.unavailable(reason)) }
        guard text.filter(\.isLetter).count >= 60 else { return .failure(.tooLittleText) }
        let budget = StudyAI.characterBudget(for: model, reservedTokens: 700, cap: 8000)
        return await summary(of: String(text.prefix(budget)), title: title, retries: 2, waitedForBudget: false)
    }

    private func summary(of excerpt: String, title: String?, retries: Int, waitedForBudget: Bool) async -> Result<[String], StudyAIProblem> {
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let prompt = [title.map { "Title: \($0)" }, "File:\n\(excerpt)"].compactMap { $0 }.joined(separator: "\n")
        do {
            let found = try await AIDeadline.run(within: StudyAI.answerLimit) {
                try await session.respond(
                    to: prompt,
                    generating: GeneratedSummary.self,
                    includeSchemaInPrompt: true,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400)
                ).content.points
            }
            let points = found
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return points.isEmpty ? .failure(.failed(String(localized: "It gave no points.", bundle: .module))) : .success(points)
        } catch {
            switch StudyAI.failure(for: error) {
            case .declined:
                return .failure(.declined)
            case .tooLong where retries > 0:
                return await summary(of: String(excerpt.prefix(excerpt.count / 3)), title: title, retries: retries - 1, waitedForBudget: waitedForBudget)
            case .tooLong:
                return .failure(.failed(error.localizedDescription))
            case .rateLimited(let wait) where !waitedForBudget:
                try? await Task.sleep(for: wait)
                return await summary(of: excerpt, title: title, retries: retries, waitedForBudget: true)
            case .rateLimited:
                return .failure(.unavailable(String(localized: "The on-device AI is busy. Try again in a minute.", bundle: .module)))
            case .unsupportedLanguage:
                return .failure(.unsupportedLanguage)
            case .tooSlow:
                return .failure(.failed(String(localized: "The on-device AI took too long to answer", bundle: .module)))
            case .other(let detail):
                return .failure(.failed(detail))
            }
        }
    }
}

@Generable(description: "What a file is about")
struct GeneratedSummary {
    @Guide(description: "The file's main points, each a short sentence", .count(2...5))
    var points: [String]
}
