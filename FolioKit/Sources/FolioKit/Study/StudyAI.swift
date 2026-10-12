import Foundation
import FoundationModels

/// Why the on-device AI couldn't write cards or a summary.
public enum StudyAIProblem: Error, Hashable, Sendable {
    /// Apple Intelligence is off, still downloading, or this Mac can't run it.
    case unavailable(String)
    /// There's too little text in the file to work from.
    case tooLittleText
    /// The model declined to write about the file.
    case declined
    /// The model doesn't read the file's language yet.
    case unsupportedLanguage
    /// Something else went wrong, in the system's words.
    case failed(String)

    public var message: String {
        switch self {
        case .unavailable(let reason): reason
        case .tooLittleText: String(localized: "There isn't enough text in this file to work from.", bundle: .module)
        case .declined: String(localized: "The on-device AI declined to write about this file.", bundle: .module)
        case .unsupportedLanguage: String(localized: "The on-device AI doesn't read this file's language yet.", bundle: .module)
        case .failed(let detail): String(localized: "The on-device AI couldn't finish: \(detail)", bundle: .module)
        }
    }
}

/// What the study tools share for using Apple's on-device model.
enum StudyAI {
    /// The general model, which writes better than the content-tagging one.
    /// The text is the student's own, and can cover sensitive history and
    /// health topics, so it uses the guardrails for transforming content.
    static func model() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    /// Why the model can't be used right now, or `nil` if it can.
    static func unavailableReason(_ model: SystemLanguageModel) -> String? {
        switch model.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): String(localized: "This Mac can't run Apple Intelligence", bundle: .module)
        case .unavailable(.appleIntelligenceNotEnabled): String(localized: "Apple Intelligence is turned off", bundle: .module)
        case .unavailable(.modelNotReady): String(localized: "Apple Intelligence is still downloading", bundle: .module)
        case .unavailable: String(localized: "Apple Intelligence isn't available", bundle: .module)
        }
    }

    /// How long to wait for the system's AI budget to come back, at most.
    static let longestWaitForRateLimit: Duration = .seconds(20)

    /// The longest Folio waits for one answer: cards from one part of a file, or a summary.
    static let answerLimit: Duration = .seconds(90)

    /// What an error from the model means for the student.
    enum Failure {
        case declined
        case tooLong
        case tooSlow
        case rateLimited(Duration)
        case unsupportedLanguage
        case other(String)
    }

    static func failure(for error: any Error) -> Failure {
        switch error {
        case is AIDeadline.Exceeded, LanguageModelError.timeout:
            return .tooSlow
        case LanguageModelError.guardrailViolation, LanguageModelError.refusal:
            return .declined
        case LanguageModelError.contextSizeExceeded:
            return .tooLong
        case LanguageModelError.rateLimited(let limit):
            let wait = limit.resetDate.map { Duration.seconds(max(1, min($0.timeIntervalSinceNow, 20))) } ?? .seconds(3)
            return .rateLimited(min(wait, longestWaitForRateLimit))
        case LanguageModelError.unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        default:
            // Errors from before macOS 27's LanguageModelError can still describe a refusal.
            let description = String(describing: error)
            if description.lowercased().contains("guardrail") || description.lowercased().contains("refusal") { return .declined }
            if description.lowercased().contains("context") && description.lowercased().contains("exceed") { return .tooLong }
            return .other(error.localizedDescription)
        }
    }

    /// How many characters of text fit in the model's context with room for
    /// the instructions and answer. Text averages about three characters a
    /// token; Chinese, Japanese and Korean far fewer, and those are cut down
    /// again if they don't fit.
    static func characterBudget(for model: SystemLanguageModel, reservedTokens: Int, cap: Int) -> Int {
        min(cap, max(1500, (model.contextSize - reservedTokens) * 3))
    }
}
