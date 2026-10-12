import Foundation
import Testing
@testable import FolioKit

struct FlashcardTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }

    /// 7 pm on a Monday.
    var evening: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 19))!
    }

    @Test func aKnownCardMovesUpABoxAndWaitsLonger() {
        let card = Flashcard(subjectID: UUID(), question: "What is Lenz's law?", answer: "The induced current opposes the change in flux.", due: evening)
        let once = card.answered(knewIt: true, at: evening, calendar: calendar)
        #expect(once.box == 2)
        #expect(once.reviewCount == 1)
        // Three days later, first thing in the morning.
        #expect(once.due == calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)))

        let twice = once.answered(knewIt: true, at: once.due, calendar: calendar)
        #expect(twice.box == 3)
        #expect(twice.due == calendar.date(from: DateComponents(year: 2026, month: 10, day: 22)))
        #expect(!twice.isLearnt)
        #expect(twice.answered(knewIt: true, at: twice.due, calendar: calendar).isLearnt)
    }

    @Test func aMissedCardGoesBackToTheFirstBox() {
        let card = Flashcard(subjectID: UUID(), question: "q", answer: "a", box: 4, due: evening)
        let missed = card.answered(knewIt: false, at: evening, calendar: calendar)
        #expect(missed.box == 1)
        #expect(missed.missCount == 1)
        #expect(missed.due == calendar.date(from: DateComponents(year: 2026, month: 10, day: 13)))
    }

    @Test func theTopBoxComesBackMonthly() {
        let card = Flashcard(subjectID: UUID(), question: "q", answer: "a", box: 5, due: evening)
        let known = card.answered(knewIt: true, at: evening, calendar: calendar)
        #expect(known.box == 5)
        #expect(known.due == calendar.date(from: DateComponents(year: 2026, month: 11, day: 11)))
    }

    @Test func dueCardsComeMostOverdueFirstThenLeastKnown() {
        let subject = UUID()
        let cards = [
            Flashcard(subjectID: subject, question: "later", answer: "a", box: 1, due: evening.addingTimeInterval(3600)),
            Flashcard(subjectID: subject, question: "known", answer: "a", box: 3, due: evening.addingTimeInterval(-86_400)),
            Flashcard(subjectID: subject, question: "shaky", answer: "a", box: 1, due: evening.addingTimeInterval(-86_400)),
            Flashcard(subjectID: subject, question: "oldest", answer: "a", box: 2, due: evening.addingTimeInterval(-3 * 86_400)),
        ]
        #expect(Flashcard.dueCards(cards, at: evening).map(\.question) == ["oldest", "shaky", "known"])
        #expect(Flashcard.dueCards(cards, at: evening, limit: 2).count == 2)
    }

    @Test func aSkippedSessionCountsForNothing() {
        let start = evening
        var session = StudySession(subjectID: UUID(), start: start, end: start.addingTimeInterval(3600))
        #expect(session.minutesDone(at: start.addingTimeInterval(7200)) == 60)
        session.outcome = .skipped
        #expect(session.minutesDone(at: start.addingTimeInterval(7200)) == 0)
        #expect(session.isRecorded)
        session.outcome = .partly
        session.doneMinutes = 25
        #expect(session.minutesDone(at: start.addingTimeInterval(7200)) == 25)
    }
}

struct CardCheckTests {
    let notes = """
        Faraday's law: an emf is induced in a conductor when the magnetic flux through it changes.
        Lenz's law: the induced current opposes the change in flux that produced it.
        Phenolphthalein changes colour at about pH 8.2 to 10.
        The oxidation of primary alcohols gives aldehydes. Transformers change alternating voltages.
        """

    @Test func answersHaveToBeInTheNotes() {
        #expect(CardCheck.isGrounded("The induced current opposes the change in flux", in: notes))
        #expect(CardCheck.isGrounded("about pH 8.2 to 10", in: notes))
        // Other endings count: "alcohol", "transformer".
        #expect(CardCheck.isGrounded("A primary alcohol is oxidised to an aldehyde", in: notes))
        // A number that isn't in the notes never counts.
        #expect(!CardCheck.isGrounded("At pH 7", in: notes))
        #expect(!CardCheck.isGrounded("Newton's third law of motion", in: notes))
        // Short answers must be there in full.
        #expect(CardCheck.isGrounded("emf", in: notes))
        #expect(!CardCheck.isGrounded("F = ma", in: notes))
    }

    @Test func markdownEmphasisIsRemovedButMathsIsKept() {
        #expect(CardCheck.plain("What is a key theme of *Nineteen Eighty-Four*?") == "What is a key theme of Nineteen Eighty-Four?")
        #expect(CardCheck.plain("**Lenz's law**: the induced current opposes the change") == "Lenz's law: the induced current opposes the change")
        #expect(CardCheck.plain("Work out 2*x*y when x = 3") == "Work out 2*x*y when x = 3")
        #expect(CardCheck.plain("3 * 4 = 12") == "3 * 4 = 12")
        let sorted = CardCheck.sort([CardDraft(question: "What does *Lenz's law* say?", answer: "The induced current opposes the change in flux.")], notes: notes, existing: [])
        #expect(sorted.kept.map(\.question) == ["What does Lenz's law say?"])
    }

    @Test func chineseIsComparedACharacterAtATime() {
        let chinese = "“了”放在动词后面表示动作已经完成。"
        #expect(CardCheck.isGrounded("表示动作已经完成", in: chinese))
        #expect(!CardCheck.isGrounded("表示将来的计划", in: chinese))
    }

    @Test func cardsAboutTheNotesOrThatRepeatTheQuestionAreDropped() {
        #expect(CardCheck.isWellFormed(CardDraft(question: "What is Lenz's law?", answer: "The induced current opposes the change in flux.")))
        #expect(!CardCheck.isWellFormed(CardDraft(question: "What is the title of these notes?", answer: "Induction")))
        #expect(!CardCheck.isWellFormed(CardDraft(question: "How does a transformer reduce energy losses?", answer: "Reduce energy losses in power transmission.")))
        #expect(!CardCheck.isWellFormed(CardDraft(question: "emf", answer: "emf")))
    }

    @Test func repeatsAreDropped() {
        let kept = [CardDraft(question: "What is Faraday's law?", answer: "An emf is induced when the flux changes.")]
        #expect(CardCheck.isRepeat(CardDraft(question: "What is Faraday's law?", answer: "A changing flux induces an emf."), of: kept))
        #expect(!CardCheck.isRepeat(CardDraft(question: "What is Lenz's law?", answer: "The current opposes the change."), of: kept))
    }

    @Test func sortingKeepsGoodCardsAndCountsTheRest() {
        let drafts = [
            CardDraft(question: "What is Lenz's law?", answer: "The induced current opposes the change in flux that produced it."),
            CardDraft(question: "What is Coulomb's law?", answer: "Force between charges is proportional to their product."),
            CardDraft(question: "What does Lenz's law say?", answer: "The induced current opposes the change in flux that produced it."),
            CardDraft(question: "Who wrote these notes?", answer: "A student"),
        ]
        let sorted = CardCheck.sort(drafts, notes: notes, existing: [])
        #expect(sorted.kept.map(\.question) == ["What is Lenz's law?"])
        #expect(sorted.kept.first?.quote == "Lenz's law: the induced current opposes the change in flux that produced it.")
        #expect(sorted.notInNotes == 1)
        #expect(sorted.repeats == 1)
        #expect(sorted.malformed == 1)
    }

    @Test func decimalsDontEndSentences() {
        #expect(CardCheck.sentences(of: "It changes at pH 8.2 to 10. Then it stops.") == ["It changes at pH 8.2 to 10.", "Then it stops."])
        #expect(CardCheck.sentences(of: "了表示完成。天冷了。") == ["了表示完成。", "天冷了。"])
    }

    @Test func notesAreSplitIntoPartsSpreadThroughTheFile() {
        let lines = (1...40).map { "Line \($0) says something about the topic in a sentence of about sixty characters." }
        let parts = CardCheck.parts(of: lines.joined(separator: "\n"), length: 400, maxParts: 3)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.count <= 400 })
        #expect(parts.first?.hasPrefix("Line 1 ") == true)
        #expect(parts.last?.contains("Line 40 ") == true)

        // A long paragraph is split between sentences, and a short last part joins the one before.
        let paragraph = String(repeating: "Alkanes are saturated hydrocarbons. ", count: 20) + "End."
        let split = CardCheck.parts(of: paragraph, length: 300, maxParts: 10)
        #expect(split.count >= 2)
        #expect(split.allSatisfy { !$0.hasPrefix(" ") })
        #expect(split.last?.hasSuffix("End.") == true)
    }

    @Test func questionPapersAreRecognised() {
        let paper = """
            2021 Physics trial examination, Section II
            Question 21 (4 marks) A projectile is launched at 20 m s⁻¹. Calculate its maximum height.
            Question 22 (5 marks) Explain how a transformer can reduce energy losses.
            Question 23 (3 marks) Describe one piece of evidence for the Big Bang theory.
            """
        #expect(CardWriter.looksLikeQuestions(paper))
        #expect(!CardWriter.looksLikeQuestions(notes))
        let worksheet = "Kinematics questions\n1. A car accelerates from rest to 27 m/s in 9 s. Find its acceleration.\n2. How far does it travel?\n3. What is its average speed?"
        #expect(CardWriter.looksLikeQuestions(worksheet))
    }

    @Test func plainRepliesAreReadAsCards() {
        let reply = """
            Here are some flashcards:
            1. **Q:** What is Faraday's law?
            **A:** An emf is induced when the flux changes.
            Q: What is Lenz's law?
            A: The induced current opposes the change.
            Question 3: What does a transformer change?
            Answer 3: Alternating voltages.
            """
        let cards = CardWriter.plainCards(in: reply)
        #expect(cards.map(\.question) == ["What is Faraday's law?", "What is Lenz's law?", "What does a transformer change?"])
        #expect(cards.last?.answer == "Alternating voltages.")
    }
}

struct LibrarySearchTests {
    let ids = (0..<6).map { _ in UUID() }

    var search: LibrarySearch {
        LibrarySearch([
            LibrarySearch.Document(id: ids[0], name: "Electromagnetism notes.docx", text: "Electromagnetic induction. Faraday's law: an emf is induced when the flux changes. Lenz's law."),
            LibrarySearch.Document(id: ids[1], name: "Calculus worksheet.pdf", text: "Differentiate each function. Find the derivative of y = x squared. Differentiation from first principles."),
            LibrarySearch.Document(id: ids[2], name: "Narrative voice slides.pdf", text: "First person narrators are different from third person narrators. The difference matters."),
            LibrarySearch.Document(id: ids[3], name: "Slavery sources.pdf", text: "A plantation in the American South. Enslaved people were sold at auction."),
            LibrarySearch.Document(id: ids[4], name: "Titration report.docx", text: "An acid was titrated against a standardised base. The titration used a burette."),
            LibrarySearch.Document(id: ids[5], name: "Acids notes.txt", text: "Acids donate protons. Strong acids ionise completely. The pH of an acid is below 7."),
        ])
    }

    @Test func rareWordsFindTheRightFile() {
        let results = search.search("electromagnetic induction")
        #expect(results.first?.id == ids[0])
        #expect(results.first?.matched.sorted() == ["electromagnetic", "induction"])
    }

    @Test func otherEndingsCountButOtherWordsDont() {
        // "differentiation" finds "differentiate", not "different".
        let results = search.search("differentiation")
        #expect(results.map(\.id) == [ids[1]])
        // "plants" isn't "plantation".
        #expect(search.search("plants").isEmpty)
        // A plural finds the singular.
        #expect(search.search("titrations").first?.id == ids[4])
    }

    @Test func wordsInNoFileDontCount() {
        // Only "sonnet"-like words in no file: nothing to show.
        #expect(search.search("photosynthesis chloroplasts").isEmpty)
        // "acid" is in two files; "neutralisation" is in none, so the acid files still come up.
        let results = search.search("acid neutralisation")
        #expect(Set(results.map(\.id)) == [ids[4], ids[5]])
    }

    @Test func aFileNeedsEnoughOfTheSearch() {
        // "auction" is rare and found; "volcano" isn't anywhere, so "auction" alone decides.
        #expect(search.search("auction volcano").map(\.id) == [ids[3]])
        // "first" and "person" both in the slides; the calculus sheet only has "first".
        #expect(search.search("first person").first?.id == ids[2])
    }

    @Test func relatedFilesShareRareWords() {
        let related = search.related(to: ids[5], limit: 3)
        #expect(related.first?.id == ids[4])
        #expect(!related.contains { $0.id == ids[5] })
    }

    @Test func formsAreRecognised() {
        #expect(LibrarySearch.isForm("ionised", of: "ionise"))
        #expect(LibrarySearch.isForm("differentiate", of: "differentiation"))
        #expect(LibrarySearch.isForm("reaction", of: "reacted"))
        #expect(!LibrarySearch.isForm("different", of: "differentiation"))
        #expect(!LibrarySearch.isForm("simile", of: "similar"))
        #expect(!LibrarySearch.isForm("plants", of: "plantation"))
    }
}

struct MeaningIndexTests {
    @Test func closerVectorsRankFirstAfterCentring() {
        let model = "test"
        let a = UUID(), b = UUID(), c = UUID()
        let index = MeaningIndex([
            MeaningIndex.Item(id: a, embedding: TextEmbedder.Embedding(vector: [1, 0.1, 0], model: model)),
            MeaningIndex.Item(id: b, embedding: TextEmbedder.Embedding(vector: [0, 1, 0.1], model: model)),
            MeaningIndex.Item(id: c, embedding: TextEmbedder.Embedding(vector: [0.1, 0, 1], model: model)),
        ])
        let matches = index.matches(for: TextEmbedder.Embedding(vector: [0.9, 0.2, 0], model: model), limit: 3, minimumSimilarity: -1)
        #expect(matches.first?.id == a)
        #expect(index.related(to: a, limit: 2, minimumSimilarity: -1).allSatisfy { $0.id != a })
        // Another model's vectors can't be compared.
        #expect(index.matches(for: TextEmbedder.Embedding(vector: [1, 0, 0], model: "other")).isEmpty)
    }
}

struct PastPapersTests {
    @Test func nesaPapersPairWithTheirMarkingGuidelines() {
        let papers = PastPapers.papers(from: [
            PastPapers.File(name: "2023-hsc-physics.pdf", year: 2023, exam: "HSC"),
            PastPapers.File(name: "2023-hsc-physics-mg.pdf"),
            PastPapers.File(name: "2021-hsc-physics.pdf", year: 2021, exam: "HSC"),
            PastPapers.File(name: "2019 trial physics.pdf"),
            PastPapers.File(name: "2019 trial physics solutions.pdf"),
        ])
        #expect(papers.map(\.title) == ["2023 HSC", "2021 HSC", "2019 Trial"])
        #expect(papers[0].guidelines.map(\.name) == ["2023-hsc-physics-mg.pdf"])
        #expect(papers[1].guidelines.isEmpty)
        #expect(papers[2].guidelines.map(\.name) == ["2019 trial physics solutions.pdf"])
    }

    @Test func cambridgeAndAQAPapersPairByPaperNumber() {
        let papers = PastPapers.papers(from: [
            PastPapers.File(name: "9702_s23_qp_42.pdf"),
            PastPapers.File(name: "9702_s23_qp_22.pdf"),
            PastPapers.File(name: "9702_s23_ms_42.pdf"),
            PastPapers.File(name: "AQA A-level Physics Paper 1 June 2018.pdf"),
            PastPapers.File(name: "AQA A-level Physics Paper 2 June 2018.pdf"),
            PastPapers.File(name: "AQA A-level Physics Paper 2 June 2018 Mark scheme.pdf"),
        ])
        let byName = Dictionary(uniqueKeysWithValues: papers.map { ($0.file.name, $0) })
        #expect(byName["9702_s23_qp_42.pdf"]?.guidelines.map(\.name) == ["9702_s23_ms_42.pdf"])
        #expect(byName["9702_s23_qp_22.pdf"]?.guidelines.isEmpty == true)
        #expect(byName["9702_s23_qp_42.pdf"]?.year == 2023)
        #expect(byName["AQA A-level Physics Paper 2 June 2018.pdf"]?.guidelines.count == 1)
        #expect(byName["AQA A-level Physics Paper 1 June 2018.pdf"]?.guidelines.isEmpty == true)
        #expect(byName["AQA A-level Physics Paper 2 June 2018.pdf"]?.title == "2018 · Paper 2")
    }

    @Test func guidelinesWithoutTheirPaperStandAlone() {
        let papers = PastPapers.papers(from: [PastPapers.File(name: "2022-hsc-chemistry-mg.pdf")])
        #expect(papers.count == 1)
        #expect(papers[0].isGuidelinesOnly)
    }

    @Test func packsKindsOfPaperAreRecognised() {
        let kinds = PackLibrary.packs.flatMap(\.documentTypes).filter(PastPapers.holdsPapers).map(\.name)
        #expect(Set(kinds) == ["Past Papers", "Mark Schemes", "Markschemes", "Practice Exams", "Exams"])
        #expect(PastPapers.isGuidelines("2023-hsc-physics-mg.pdf"))
        #expect(PastPapers.isGuidelines("Physics paper 1 HL markscheme.pdf"))
        #expect(!PastPapers.isGuidelines("2023-hsc-physics.pdf"))
        #expect(PastPapers.year(in: "9702_w22_qp_12.pdf") == 2022)
    }
}

struct ClaudeCardWriterTests {
    let notes = """
        Faraday's law: an emf is induced in a conductor when the magnetic flux through it changes.
        Lenz's law: the induced current opposes the change in flux that produced it.
        """

    @Test func theRequestAsksForCardsWithQuotes() throws {
        let data = try ClaudeCardWriter.requestBody(for: notes, subject: "Physics")
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-5-5")
        let format = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let items = try #require(((schema["properties"] as? [String: Any])?["cards"] as? [String: Any])?["items"] as? [String: Any])
        #expect(Set(items["required"] as? [String] ?? []) == ["question", "answer", "quote"])
        let text = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.hasPrefix("Subject: Physics\nNotes:\nFaraday's law") == true)
    }

    @Test func cardsAreCheckedAgainstTheNotes() async throws {
        let cards: [[String: Any]] = [
            ["question": "What is Lenz's law?", "answer": "The induced current opposes the change in flux.", "quote": "Lenz's law: the induced current opposes the change in flux that produced it."],
            ["question": "What is Faraday's law?", "answer": "An emf is induced when the magnetic flux changes.", "quote": "A sentence that isn't in the notes."],
            ["question": "What is Ohm's law?", "answer": "Voltage equals current times resistance.", "quote": "V = IR"],
        ]
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: ["cards": cards]), as: UTF8.self)
        let session = CannedClaude.session(key: "cards-ok", responses: [CannedClaude.Response(body: CannedClaude.message(answer))])
        let ledger = ClaudeUsageLedger(defaults: UserDefaults(suiteName: "ClaudeCardWriterTests-\(UUID())")!)
        let result = await ClaudeCardWriter(key: "cards-ok", ledger: ledger, session: session).cards(from: notes, subject: "Physics")

        #expect(result.problem == nil)
        #expect(result.drafts.map(\.question) == ["What is Lenz's law?", "What is Faraday's law?"])
        #expect(result.notInNotes == 1)
        // A quote that isn't in the notes is replaced with the sentence that is.
        #expect(result.drafts[1].quote == "Faraday's law: an emf is induced in a conductor when the magnetic flux through it changes.")
        #expect(ledger.usage().requests == 1)
    }

    @Test func problemsAreReported() async {
        let refused = CannedClaude.session(key: "cards-refused", responses: [CannedClaude.Response(body: CannedClaude.message(nil, stopReason: "refusal"))])
        #expect(await ClaudeCardWriter(key: "cards-refused", session: refused).cards(from: notes, subject: "Physics").problem == .refused)
        let badKey = CannedClaude.session(key: "cards-bad", responses: [CannedClaude.Response(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        #expect(await ClaudeCardWriter(key: "cards-bad", session: badKey).cards(from: notes, subject: "Physics").problem == .badKey)
        let offline = CannedClaude.session(key: "cards-offline", responses: [])
        #expect(await ClaudeCardWriter(key: "cards-offline", session: offline).cards(from: notes, subject: "Physics").problem == .offline)
    }
}

struct PaperTimesTests {
    @Test func workingAndReadingTimesAreRead() {
        let hsc = PastPapers.times(in: "Physics General Instructions • Reading time – 5 minutes • Working time – 3 hours • Draw diagrams using pencil")
        #expect(hsc.working == 180)
        #expect(hsc.reading == 5)
        #expect(PastPapers.times(in: "AQA. June 2019. Time allowed: 1 hour 30 minutes. Materials: a calculator").working == 90)
        #expect(PastPapers.times(in: "International Baccalaureate. November 2020. 2 hours 15 minutes. Instructions to candidates").working == 135)
        #expect(PastPapers.times(in: "ÉPREUVE DE SPÉCIALITÉ : MATHÉMATIQUES Durée de l'épreuve : 4 heures. L'usage de la calculatrice").working == 240)
        #expect(PastPapers.times(in: "Section II. Question 21 (4 marks). A satellite is in a circular orbit.").working == nil)
    }
}

struct AIDeadlineTests {
    struct Failure: Error {}

    @Test func aQuickAnswerComesBack() async throws {
        let value = try await AIDeadline.run(within: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func anErrorComesBack() async {
        await #expect(throws: Failure.self) {
            try await AIDeadline.run(within: .seconds(5)) { () async throws -> Int in throw Failure() }
        }
    }

    @Test func aRequestThatNeverAnswersIsGivenUpOn() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: AIDeadline.Exceeded.self) {
            // Ignores cancellation, as a stuck request to the model would.
            try await AIDeadline.run(within: .milliseconds(200)) { () async throws -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 0
            }
        }
        #expect(clock.now - start < .seconds(5))
    }
}
