import Foundation
import FoundationModels
import Testing
@testable import FolioKit
import FolioTestSupport

struct KeywordVoterTests {
    let profile = Profile.starter()

    func evidence(_ text: String, fileName: String = "file.pdf", title: String? = nil) -> Evidence {
        Evidence(fileName: fileName, contentType: "com.adobe.pdf", title: title, text: text)
    }

    @Test func subjectNameInTheHeaderIsStrongEvidence() async {
        let paper = evidence("2023 HIGHER SCHOOL CERTIFICATE EXAMINATION\nModern History\nSection I Core Study: Power and Authority in the Modern World 1919–1946. Explain the growth of the Nazi Party.")
        let vote = await KeywordVoter().vote(on: paper, profile: profile)

        #expect(vote.top?.id == profile.subject(named: "History")?.id)
        #expect(vote.strength >= 9)
        #expect((vote.top?.score ?? 0) >= 0.7)
    }

    @Test func accentsAndCaseAreIgnored() async {
        let vote = await KeywordVoter().vote(on: evidence("BACCALAURÉAT GÉNÉRAL — MATHÉMATIQUES. Calculer la dérivée de la fonction."), profile: profile)
        #expect(vote.top?.id == profile.subject(named: "Mathematics")?.id)
    }

    @Test func wordsMustBeWholeWords() async {
        // "war" inside "software" and "reward" must not count for History.
        let vote = await KeywordVoter().vote(on: evidence("The software reward program was updated."), profile: profile)
        #expect(vote.abstention?.kind == .noEvidence)
    }

    @Test func simplePluralsMatch() {
        #expect(TermMatcher.count(of: "logarithm", in: "logarithms and exponentials") == 1)
        #expect(TermMatcher.count(of: "process", in: "two processes") == 1)
        #expect(TermMatcher.count(of: "war", in: "wars, warships and software") == 1)
    }

    @Test func nothingFoundMeansNoVote() async {
        let vote = await KeywordVoter().vote(on: evidence("Order #48213. 1x Large Pepperoni Pizza $14.95."), profile: profile)
        #expect(vote.abstention != nil)
        #expect(vote.scores.isEmpty)
    }

    @Test func theFolderAFileCameFromIsIgnored() async {
        var file = evidence("Order #48213. 1x Large Pepperoni Pizza $14.95.")
        file.folderName = "History"
        let vote = await KeywordVoter().vote(on: file, profile: profile)
        #expect(vote.abstention != nil)
    }
}

struct ArbiterTests {
    let profile = Profile.starter()
    var history: Subject.ID { profile.subject(named: "History")!.id }
    var physics: Subject.ID { profile.subject(named: "Physics")!.id }
    var chemistry: Subject.ID { profile.subject(named: "Chemistry")!.id }
    let file = Evidence(fileName: "file.pdf", contentType: "com.adobe.pdf")

    func keywords(_ id: Subject.ID, share: Double, strength: Double) -> Vote {
        Vote(voter: .keywords, scores: [id: share], strength: strength, reasons: ["Found words"])
    }

    func model(_ id: Subject.ID) -> Vote {
        Vote(voter: .model, scores: [id: 1], strength: 1, reasons: ["On-device AI"])
    }

    @Test func agreeingSignalsFileAtEveryLevel() {
        for level in AutoFileLevel.allCases {
            let decision = Arbiter(level: level).decide([keywords(history, share: 0.5, strength: 4), model(history)], evidence: file, profile: profile)
            #expect(decision.outcome == .file(history))
        }
    }

    @Test func disagreementAsksWithBothSuggestions() {
        let decision = Arbiter(level: .eager).decide([keywords(chemistry, share: 0.5, strength: 4), model(physics)], evidence: file, profile: profile)
        #expect(decision.outcome == .review)
        #expect(Set(decision.suggestions) == [chemistry, physics])
    }

    @Test func strongKeywordsAloneFileAtBalancedButNotCareful() {
        // The on-device AI refused, as it did for a Nazi Germany history paper.
        let votes = [keywords(history, share: 0.85, strength: 15), Vote.abstained(.model, .declined, "The on-device AI declined to read this file")]

        #expect(Arbiter(level: .careful).decide(votes, evidence: file, profile: profile).outcome == .review)
        let balanced = Arbiter(level: .balanced).decide(votes, evidence: file, profile: profile)
        #expect(balanced.outcome == .file(history))
        #expect(balanced.reasons.contains("The on-device AI declined to read this file"))
    }

    @Test func weakKeywordsAloneAlwaysAsk() {
        let votes = [keywords(history, share: 0.25, strength: 1), Vote.abstained(.model, .unavailable, "Apple Intelligence is turned off")]
        #expect(Arbiter(level: .balanced).decide(votes, evidence: file, profile: profile).outcome == .review)
    }

    @Test func notSchoolworkIsLeftAlone() {
        let votes = [
            Vote.abstained(.keywords, .noEvidence, "No subject words found"),
            Vote(voter: .model, scores: [:], notSchoolwork: 1, reasons: ["On-device AI: doesn't look like schoolwork"]),
        ]
        #expect(Arbiter(level: .careful).decide(votes, evidence: file, profile: profile).outcome == .notSchoolwork)
    }

    @Test func keywordsAgainstNotSchoolworkAsks() {
        let votes = [keywords(history, share: 0.85, strength: 15), Vote(voter: .model, scores: [:], notSchoolwork: 1)]
        #expect(Arbiter(level: .eager).decide(votes, evidence: file, profile: profile).outcome == .review)
    }

    @Test func theAIAndSimilarFilesAloneDontFileAtCareful() {
        let maths = profile.subject(named: "Mathematics")!.id
        let votes = [
            Vote.abstained(.keywords, .noEvidence, "No subject words found"),
            Vote(voter: .examples, scores: [maths: 1], strength: 0.14, reasons: ["Like “Integration practice.pdf” in Mathematics"]),
            model(maths),
        ]
        #expect(Arbiter(level: .careful).decide(votes, evidence: file, profile: profile).outcome == .review)
        #expect(Arbiter(level: .balanced).decide(votes, evidence: file, profile: profile).outcome == .review)
    }

    @Test func wordsAndSimilarFilesFileWhenTheAIIsOff() {
        let votes = [
            keywords(history, share: 0.5, strength: 4),
            Vote(voter: .examples, scores: [history: 1], strength: 0.2, reasons: ["Like “Cold War notes.docx” in History"]),
            Vote.abstained(.model, .unavailable, "Apple Intelligence is turned off"),
        ]
        #expect(Arbiter(level: .careful).decide(votes, evidence: file, profile: profile).outcome == .file(history))
    }

    @Test func similarFilesDisagreeingMeansAsking() {
        let votes = [keywords(history, share: 0.5, strength: 4), model(history), Vote(voter: .examples, scores: [physics: 1], strength: 0.2)]
        #expect(Arbiter(level: .careful).decide(votes, evidence: file, profile: profile).outcome == .review)
    }

    @Test func aRuleWinsOutright() {
        let rule = Vote(voter: .rules, scores: [chemistry: 1], strength: 1, reasons: ["Your rule"])
        let decision = Arbiter(level: .careful).decide([rule, model(physics)], evidence: file, profile: profile)
        #expect(decision.outcome == .file(chemistry))
    }

    @Test func nothingAtAllAsks() {
        let votes = [Vote.abstained(.keywords, .noEvidence, "No subject words found"), Vote.abstained(.model, .failed, "Couldn't answer")]
        let decision = Arbiter(level: .eager).decide(votes, evidence: file, profile: profile)
        #expect(decision.outcome == .review)
        #expect(decision.suggestions.isEmpty)
    }
}

struct FacetHeuristicsTests {
    let profile = Profile.starter()

    @Test func examPapersAreRecognisedByTheirInstructions() {
        let paper = Evidence(fileName: "IB Physics HL Paper 2.pdf", contentType: "com.adobe.pdf", text: "Physics — Higher level. 2 hours 15 minutes. Instructions to candidates: Answer all questions.")
        #expect(FacetHeuristics.facets(for: paper, profile: profile).documentType == "Past Papers")
    }

    @Test func filesThatDontSayTheirTypeGetTheDefault() {
        let notes = Evidence(fileName: "IMG_4100.jpg", contentType: "public.jpeg", text: "p = mv\nImpulse = F Δt")
        let decision = Arbiter(level: .careful).decide([Vote.abstained(.keywords, .noEvidence, "None")], evidence: notes, profile: profile)
        #expect(decision.facets.documentType == "Notes")
    }

    @Test func findsExamYearAndType() {
        let paper = Evidence(fileName: "paper.pdf", contentType: "com.adobe.pdf", text: "2023 HIGHER SCHOOL CERTIFICATE EXAMINATION\nModern History\nPower and Authority 1919–1946")
        let facets = FacetHeuristics.facets(for: paper, profile: profile)
        #expect(facets.exam == "HSC")
        #expect(facets.year == 2023)
        #expect(facets.documentType == "Past Papers")
    }

    @Test func historicalDatesInNotesAreNotTheDocumentYear() {
        let notes = Evidence(fileName: "Cold War notes.docx", contentType: "org.openxmlformats.wordprocessingml.document", text: "The Cuban Missile Crisis of 1962 and the fall of the Berlin Wall in 1989; the USSR dissolved in 1991.")
        let facets = FacetHeuristics.facets(for: notes, profile: profile)
        #expect(facets.year == nil)
        #expect(facets.documentType == "Notes")
    }

    @Test func theAIsYearOnlyCountsForExamPapers() {
        let notes = Evidence(fileName: "Holocaust research notes.docx", contentType: "org.openxmlformats.wordprocessingml.document", text: "Research notes. In 1941 the Nazi regime began the systematic murder of Europe's Jews.")
        let model = Vote(voter: .model, scores: [profile.subject(named: "History")!.id: 1], strength: 1, facets: Facets(year: 1941))
        let decision = Arbiter(level: .careful).decide([model], evidence: notes, profile: profile)
        #expect(decision.facets.year == nil)
    }

    @Test func yearInTheFileNameCounts() {
        let file = Evidence(fileName: "8464_B_1H_2019.pdf", contentType: "com.adobe.pdf", text: "AQA GCSE Combined Science: Trilogy Higher Tier Paper 1: Biology")
        let facets = FacetHeuristics.facets(for: file, profile: profile)
        #expect(facets.year == 2019)
        #expect(facets.exam == "GCSE")
    }
}

struct ModelPromptTests {
    @Test func theFileNameCanBeLeftOut() {
        let file = Evidence(fileName: "physics worksheet.pdf", contentType: "com.adobe.pdf", text: "Draw Lewis dot diagrams for water and ammonia.")
        #expect(ModelVoter.prompt(for: file, excerptLength: 100).contains("physics worksheet.pdf"))
        #expect(!ModelVoter.prompt(for: file, excerptLength: 100, includesFileName: false).contains("physics worksheet"))
    }

    @Test func theAnswerCanOnlyBeOneOfTheStudentsSubjects() throws {
        let schema = try ModelVoter.schema(for: Profile.starter())
        let description = String(describing: schema)
        #expect(description.contains("Mathematics"))
        #expect(description.contains("Unsorted"))
    }
}

@Suite(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs Apple Intelligence"))
struct ModelVoterTests {
    let profile = Profile.starter()

    @Test func sensitiveHistoryIsAnsweredAfterARefusal() async {
        let paper = Evidence(fileName: "paper.pdf", contentType: "com.adobe.pdf", text: "2023 HIGHER SCHOOL CERTIFICATE EXAMINATION\nModern History\nPower and Authority in the Modern World 1919–1946. Use Source A to explain the growth of the Nazi Party after 1929, and assess the role of propaganda and terror in consolidating the regime.")
        let vote = await ModelVoter().vote(on: paper, profile: profile)

        #expect(vote.abstention == nil)
        #expect(vote.top?.id == profile.subject(named: "History")?.id)
    }

    @Test func answersWithOneOfTheStudentsSubjects() async {
        let notes = Evidence(fileName: "IMG_4821.mov", contentType: "public.movie", text: "today we're going over how plants make their food. light hits the chlorophyll in the chloroplast and the Calvin cycle fixes carbon dioxide into glucose. know the word equation for photosynthesis.")
        let profile = Profile(
            subjects: profile.subjects + [Subject(name: "Biology", colorHex: 0x30D158, summary: "Living things: cells, plants, genetics, ecology and the human body")],
            documentTypes: profile.documentTypes,
            examBoards: profile.examBoards
        )
        let vote = await ModelVoter().vote(on: notes, profile: profile)

        #expect(vote.abstention == nil)
        #expect(vote.top?.id == profile.subject(named: "Biology")?.id)
    }

    @Test func aDiagramWithoutWordsIsSeen() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "IMG_\(UUID().uuidString.prefix(4)).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentRenderer.writeMoleculeDiagram(to: url)
        let evidence = try await Extractor().extract(from: url)
        #expect(evidence.text.count < 40)

        let vote = await ModelVoter().vote(on: evidence, profile: profile)

        #expect(vote.top?.id == profile.subject(named: "Chemistry")?.id)
        #expect(vote.reasons.first?.contains("looked at the image") == true)
    }

    @Test func receiptsAreNotSchoolwork() async {
        let receipt = Evidence(fileName: "receipt.pdf", contentType: "com.adobe.pdf", text: "Order #48213. 1x Large Pepperoni Pizza $14.95, 1x Garlic Bread $5.50. Delivery fee $4.00. Paid by card.")
        let vote = await ModelVoter().vote(on: receipt, profile: profile)

        #expect(vote.scores.isEmpty)
        #expect(vote.notSchoolwork == 1)
    }
}
