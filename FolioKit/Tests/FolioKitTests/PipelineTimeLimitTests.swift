import Foundation
import Testing
@testable import FolioKit

/// A system service that never answers mustn't stall sorting.
struct PipelineTimeLimitTests {
    /// Never answers, like the on-device AI or text recognition when they stall.
    private struct StuckVoter: Voter {
        var kind: VoterKind { .model }

        func vote(on evidence: Evidence, profile: Profile) async -> Vote {
            try? await Task.sleep(for: .seconds(3600))
            return Vote(voter: .model, scores: [:], strength: 0, reasons: [])
        }
    }

    @Test(.timeLimit(.minutes(1))) func aFileThatCantBeJudgedFailsWithoutHoldingUpTheNext() async throws {
        let temp = try TemporaryFolder()
        let first = try temp.file("Downloads/first.txt", contents: "Notes on the French Revolution")
        let second = try temp.file("Downloads/second.txt", contents: "Questions on projectile motion")
        let pipeline = SortingPipeline(classifier: Classifier(voters: [StuckVoter()]), profile: Profile.starter(), judgingLimit: .milliseconds(300))

        await pipeline.enqueue([.init(url: first), .init(url: second)])
        var failures: [String] = []
        for await event in pipeline.events {
            if case .failed(_, let message) = event { failures.append(message) }
            if failures.count == 2 { break }
        }
        #expect(failures == ["Couldn't sort this file in time", "Couldn't sort this file in time"])
        #expect(await pipeline.isIdle)
    }

    @Test func readingHasALimit() {
        #expect(Extractor().timeLimit == .seconds(600))
        #expect(Extractor.thorough.timeLimit > Extractor().timeLimit)
    }
}
