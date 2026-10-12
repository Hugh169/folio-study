import Foundation
import FoundationModels
import Testing
@testable import FolioKit

/// Records a librarian's events so tests can wait for files to finish.
@MainActor
final class EventLog {
    private(set) var outcomes: [UUID: Librarian.Event] = [:]
    private(set) var progress: [UUID: [String]] = [:]
    private var task: Task<Void, Never>?

    init(_ librarian: Librarian) {
        let events = librarian.events
        task = Task { [weak self] in
            for await event in events {
                self?.record(event)
            }
        }
    }

    private func record(_ event: Librarian.Event) {
        switch event {
        case .progress(let id, let message):
            progress[id, default: []].append(message)
        case .filed(let id, _), .needsReview(let id, _), .leftAlone(let id, _), .duplicate(let id, _), .failed(let id, _):
            outcomes[id] = event
        }
    }

    /// Waits until every ticket has an outcome.
    func wait(for tickets: [(id: UUID, name: String)], timeout: Duration = .seconds(120)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !tickets.allSatisfy({ outcomes[$0.id] != nil }) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func filed(_ ticket: (id: UUID, name: String)) -> FiledRecord? {
        if case .filed(_, let record) = outcomes[ticket.id] { return record }
        return nil
    }

    func review(_ ticket: (id: UUID, name: String)) -> ReviewRecord? {
        if case .needsReview(_, let record) = outcomes[ticket.id] { return record }
        return nil
    }
}

@MainActor
struct LibrarianTests {
    let profile: Profile
    var maths: Subject { profile.subject(named: "Mathematics")! }
    var chemistry: Subject { profile.subject(named: "Chemistry")! }

    init() {
        var profile = Profile.starter()
        let maths = profile.subject(named: "Mathematics")!
        profile.rules = [SortingRule(field: .fileName, contains: "MATH1131", subjectID: maths.id)]
        self.profile = profile
    }

    func librarian(in temp: TemporaryFolder, store: FolioStore? = nil, usesAI: Bool = false) throws -> Librarian {
        var options = Librarian.Options()
        options.usesOnDeviceAI = usesAI
        return Librarian(library: try temp.folder("School"), profile: profile, store: try store ?? FolioStore(url: nil), options: options)
    }

    let titration = "Untitled worksheet. Fill the burette with sodium hydroxide and record the titration volume. Calculate the concentration of the acid."

    @Test func aMatchingRuleFilesTheFile() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/MATH1131 week 3.txt", contents: "Questions for this week.")
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let tickets = librarian.sort([file])
        try await log.wait(for: tickets)

        let record = try #require(log.filed(tickets[0]))
        #expect(record.subjectID == maths.id)
        #expect(record.folder == "Notes")
        #expect(temp.exists("School/Mathematics/Notes/MATH1131 week 3.txt"))
        #expect(!temp.exists("Desktop/MATH1131 week 3.txt"))
        #expect(librarian.recentFiles().map(\.id) == [record.id])
        #expect(librarian.store.journal(for: record.id).count == 1)
        #expect(log.progress[tickets[0].id]?.first == "Waiting…")
    }

    @Test func unsureFilesWaitAndTheStudentsChoiceIsFiled() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/Untitled.txt", contents: titration)
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let tickets = librarian.sort([file])
        try await log.wait(for: tickets)

        // Without the AI only one signal points to Chemistry, so Careful asks.
        let review = try #require(log.review(tickets[0]))
        #expect(review.suggestions.first == chemistry.id)
        #expect(temp.exists("Desktop/Untitled.txt"))
        #expect(librarian.reviewQueue().map(\.id) == [review.id])

        let filed = try await librarian.file(review.id, in: chemistry.id)

        #expect(filed.chosenByStudent)
        #expect(temp.exists("School/Chemistry/Worksheets/Untitled.txt"))
        #expect(librarian.reviewQueue().isEmpty)
        if await TextEmbedder().isAvailable {
            #expect(await librarian.learnedExampleCount == 1)
        }
    }

    @Test func puttingBackReturnsTheFileAndAsksAgain() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/MATH1131 week 3.txt")
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)
        let tickets = librarian.sort([file])
        try await log.wait(for: tickets)
        let record = try #require(log.filed(tickets[0]))

        let review = try await librarian.putBack(record.id)

        #expect(temp.exists("Desktop/MATH1131 week 3.txt"))
        #expect(review.question.hasPrefix("Moved back to Desktop"))
        #expect(librarian.recentFiles().isEmpty)
        #expect(librarian.reviewQueue().map(\.id) == [review.id])
        #expect(librarian.store.journal(for: record.id).map(\.action) == [.file, .putBack])
    }

    @Test func duplicatesStayWhereTheyAre() async throws {
        let temp = try TemporaryFolder()
        let original = try temp.file("Desktop/MATH1131 week 3.txt", contents: "Same contents")
        let copy = try temp.file("Downloads/copy of week 3.txt", contents: "Same contents")
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let first = librarian.sort([original])
        try await log.wait(for: first)
        let second = librarian.sort([copy])
        try await log.wait(for: second)

        guard case .duplicate(_, let detail) = log.outcomes[second[0].id] else {
            Issue.record("Expected a duplicate, got \(String(describing: log.outcomes[second[0].id]))")
            return
        }
        #expect(detail == "Already filed in Mathematics · Notes")
        #expect(temp.exists("Downloads/copy of week 3.txt"))
    }

    @Test func aCopyInTheSameDropNamesTheOriginal() async throws {
        let temp = try TemporaryFolder()
        let original = try temp.file("Desktop/MATH1131 a.txt", contents: "Same contents")
        let copy = try temp.file("Desktop/MATH1131 b.txt", contents: "Same contents")
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let tickets = librarian.sort([original, copy])
        try await log.wait(for: tickets)

        let details = tickets.compactMap { ticket -> String? in
            if case .duplicate(_, let detail) = log.outcomes[ticket.id] { return detail }
            return nil
        }
        #expect(details.count == 1)
        #expect(details.first?.hasPrefix("A copy of “MATH1131") == true)
    }

    @Test func backgroundFilesThatPointNowhereAreLeftAlone() async throws {
        let temp = try TemporaryFolder()
        let download = try temp.file("Downloads/IMG_2041.txt", contents: "Meet at the station at 7.")
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let tickets = librarian.sort([download], from: .watched)
        try await log.wait(for: tickets)

        guard case .leftAlone = log.outcomes[tickets[0].id] else {
            Issue.record("Expected it to be left alone, got \(String(describing: log.outcomes[tickets[0].id]))")
            return
        }
        #expect(librarian.reviewQueue().isEmpty)
        #expect(temp.exists("Downloads/IMG_2041.txt"))
    }

    @Test func backgroundFilesWithAGuessStillWait() async throws {
        let temp = try TemporaryFolder()
        let download = try temp.file("Downloads/Untitled.txt", contents: titration)
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let tickets = librarian.sort([download], from: .watched)
        try await log.wait(for: tickets)

        #expect(log.review(tickets[0])?.suggestions.first == chemistry.id)
    }

    @Test func dueDatesInFiledFilesAreOffered() async throws {
        let temp = try TemporaryFolder()
        let due = Calendar.current.date(byAdding: .day, value: 14, to: .now)!
        let dueText = due.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "en_AU")))
        let file = try temp.file("Desktop/MATH1131 assessment.txt", contents: "Assessment task 2\nDue: \(dueText) at 5:00 pm\nShow all working.")
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let tickets = librarian.sort([file])
        try await log.wait(for: tickets)

        let reading = try #require(log.filed(tickets[0])?.reading)
        let found = try #require(reading.assessment)
        #expect(Calendar.current.isDate(found.due, inSameDayAs: due))
        #expect(Calendar.current.component(.hour, from: found.due) == 17)
        #expect(found.title == "Assessment task 2")
        #expect(reading.role == .taskSheet)
    }

    @Test func skippingLeavesTheFileAlone() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/Untitled.txt", contents: titration)
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)
        let tickets = librarian.sort([file])
        try await log.wait(for: tickets)

        librarian.skip(try #require(log.review(tickets[0])).id)

        #expect(librarian.reviewQueue().isEmpty)
        #expect(temp.exists("Desktop/Untitled.txt"))
    }

    @Test func recordsSurviveARestart() async throws {
        let temp = try TemporaryFolder()
        let storeURL = temp.url.appending(path: "Support/Folio.store")
        do {
            let librarian = try librarian(in: temp, store: FolioStore(url: storeURL))
            let log = EventLog(librarian)
            let tickets = librarian.sort([
                try temp.file("Desktop/MATH1131 week 3.txt"),
                try temp.file("Desktop/Untitled.txt", contents: titration),
            ])
            try await log.wait(for: tickets)
            librarian.shutDown()
        }

        let reopened = try librarian(in: temp, store: FolioStore(url: storeURL))

        #expect(reopened.recentFiles().map(\.name) == ["MATH1131 week 3.txt"])
        #expect(reopened.reviewQueue().map(\.name) == ["Untitled.txt"])
    }

    @Test func foldersAreOpenedUp() async throws {
        let temp = try TemporaryFolder()
        try temp.file("Desktop/Week 3/MATH1131 a.txt", contents: "Part A")
        try temp.file("Desktop/Week 3/Sub/MATH1131 b.txt", contents: "Part B")
        try temp.file("Desktop/Week 3/.hidden.txt")
        try temp.file("Desktop/Week 3/paper.pdf.crdownload")
        let librarian = try librarian(in: temp)
        let log = EventLog(librarian)

        let tickets = librarian.sort([temp.url.appending(path: "Desktop/Week 3")])
        try await log.wait(for: tickets)

        #expect(Set(tickets.map(\.name)) == ["MATH1131 a.txt", "MATH1131 b.txt"])
        #expect(temp.exists("School/Mathematics/Notes/MATH1131 a.txt"))
        #expect(temp.exists("School/Mathematics/Notes/MATH1131 b.txt"))
    }

    @Test func droppingTheWholeLibraryDoesntResortIt() throws {
        let temp = try TemporaryFolder()
        try temp.file("School/History/Notes/a.txt")
        try temp.file("Desktop/b.txt")

        let files = Librarian.files(in: temp.url, library: temp.url.appending(path: "School"))

        #expect(files.map(\.lastPathComponent) == ["b.txt"])
    }

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs Apple Intelligence"))
    func receiptsAreLeftAlone() async throws {
        let temp = try TemporaryFolder()
        let receipt = try temp.file("Downloads/receipt.txt", contents: "Order #48213. 1x Large Pepperoni Pizza $14.95, 1x Garlic Bread $5.50. Delivery fee $4.00. Paid by card.")
        let librarian = try librarian(in: temp, usesAI: true)
        let log = EventLog(librarian)

        let tickets = librarian.sort([receipt])
        try await log.wait(for: tickets)

        guard case .leftAlone = log.outcomes[tickets[0].id] else {
            Issue.record("Expected the receipt to be left alone, got \(String(describing: log.outcomes[tickets[0].id]))")
            return
        }
        #expect(temp.exists("Downloads/receipt.txt"))
        #expect(log.progress[tickets[0].id]?.contains("Asking the on-device AI…") == true)
    }
}

struct ExampleIndexTests {
    let physics = UUID()
    let history = UUID()

    func embedding(_ values: [Float]) -> TextEmbedder.Embedding {
        TextEmbedder.Embedding(vector: values, model: "test")
    }

    @Test func theClosestSubjectComesFirst() {
        let index = ExampleIndex([
            .init(subjectID: physics, name: "forces.pdf", embedding: embedding([1, 0.1, 0])),
            .init(subjectID: physics, name: "waves.pdf", embedding: embedding([0.9, 0, 0.1])),
            .init(subjectID: history, name: "ww1.pdf", embedding: embedding([0, 1, 0.1])),
            .init(subjectID: history, name: "rome.pdf", embedding: embedding([0.1, 0.9, 0])),
        ])

        let matches = index.matches(for: embedding([0.95, 0.05, 0.05]), among: [physics, history])

        #expect(matches.map(\.subjectID) == [physics, history])
        #expect(matches[0].similarity > 0.5)
    }

    @Test func embeddingsFromOtherModelsAreIgnored() {
        let index = ExampleIndex([.init(subjectID: physics, name: "a", embedding: embedding([1, 0]))])
        let other = TextEmbedder.Embedding(vector: [1, 0], model: "another")
        #expect(index.matches(for: other, among: [physics]).isEmpty)
    }
}

struct ExampleVoterTests {
    let profile = Profile.starter()

    @Test func itWaitsForEnoughExamples() async {
        let voter = ExampleVoter()
        let vote = await voter.vote(on: Evidence(fileName: "a.pdf", contentType: "com.adobe.pdf", text: "Newton's laws"), profile: profile)
        #expect(vote.abstention?.kind == .noEvidence)
    }

    @Test func itVotesForTheSubjectWhoseFilesItIsLike() async throws {
        let embedder = TextEmbedder()
        guard await embedder.isAvailable else { return }
        let physics = profile.subject(named: "Physics")!
        let history = profile.subject(named: "History")!
        let pastFiles: [(Subject, String)] = [
            (physics, "A ball is launched at 20 m/s at 30 degrees above the horizontal. Find its range and maximum height."),
            (physics, "Calculate the current through each resistor when a 12 V battery is connected in parallel."),
            (physics, "A car accelerates uniformly from rest to 25 m/s in 10 s. Find its acceleration and the distance covered."),
            (history, "Explain the causes of the First World War, including the alliance system and militarism."),
            (history, "Assess the impact of the Treaty of Versailles on Germany in the 1920s."),
            (history, "Describe the role of propaganda in the rise of the Nazi Party after 1929."),
        ]
        var examples: [ExampleIndex.Example] = []
        for (subject, text) in pastFiles {
            let embedding = try #require(await embedder.embed(text))
            examples.append(.init(subjectID: subject.id, name: "\(subject.name).txt", embedding: embedding))
        }
        let voter = ExampleVoter(embedder: embedder, examples: examples)

        let vote = await voter.vote(on: Evidence(fileName: "IMG_2231.jpg", contentType: "public.jpeg", text: "A projectile is fired horizontally from a cliff 45 m high at 15 m/s. How far from the base does it land?"), profile: profile)

        #expect(vote.top?.id == physics.id)
    }
}
