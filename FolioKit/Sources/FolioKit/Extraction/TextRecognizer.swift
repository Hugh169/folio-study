import CoreGraphics
import Foundation
import Vision

/// On-device text recognition, including handwriting, in any language Vision supports.
enum TextRecognizer {
    static func text(in image: CGImage) async throws -> String {
        lines(from: try await request().perform(on: image))
    }

    static func text(inImageAt url: URL) async throws -> String {
        lines(from: try await request().perform(on: url))
    }

    private static func request() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        return request
    }

    private static func lines(from observations: [RecognizedTextObservation]) -> String {
        observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
