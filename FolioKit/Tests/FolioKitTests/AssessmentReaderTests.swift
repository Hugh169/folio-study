import Foundation
import Testing
@testable import FolioKit

struct AssessmentReaderTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }()

    /// Saturday 10 October 2026.
    var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
    }

    func evidence(_ text: String, name: String = "Untitled.pdf") -> Evidence {
        Evidence(fileName: name, contentType: "com.adobe.pdf", text: text, method: .embeddedText)
    }

    func read(_ text: String, name: String = "Untitled.pdf", facets: Facets = Facets(), open: [Assessment] = []) -> AssessmentReader.Reading? {
        AssessmentReader.read(evidence(text, name: name), facets: facets, open: open, now: now, calendar: calendar)
    }

    @Test func anHSCNotificationGivesEveryDetail() throws {
        let reading = try #require(read("""
            Riverside High School
            Assessment Notification
            Biology – Year 12
            Task 2: Depth Study – Investigating Enzymes
            Weighting: 30%
            Due date: Friday 14 November 2026, 3:00 pm
            Outcomes assessed: BIO12-1, BIO12-7
            Total marks: 40
            """))
        let found = try #require(reading.assessment)
        #expect(found.title == "Task 2: Depth Study – Investigating Enzymes")
        #expect(found.kind == .task)
        #expect(found.weighting == 30)
        #expect(found.totalMarks == 40)
        #expect(found.due == calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15)))
        #expect(reading.role == .taskSheet)
    }

    @Test func aDepthStudyWithAPracticalInvestigationIsATask() throws {
        let found = try #require(read("""
            Assessment Notification
            Physics – Year 12
            Task 2: Depth Study – Investigating projectile motion
            Weighting: 30%
            Due date: Monday 2 November 2026, 3:00 pm
            Plan and carry out a practical investigation into projectile motion.
            """)?.assessment)
        #expect(found.kind == .task)
    }

    @Test func anExamGivesItsDateAndLength() throws {
        let found = try #require(read("""
            Year 12 Trial Examination
            Chemistry
            Exam date: Tuesday 17 November 2026, 9:00 am
            Time allowed: 3 hours
            Weighting: 25%
            """)?.assessment)
        #expect(found.kind == .exam)
        #expect(found.lengthMinutes == 180)
        #expect(found.weighting == 25)
        #expect(found.due == calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9)))
    }

    @Test func aVCESACIsATaskWithItsDate() throws {
        let found = try #require(read("""
            Mathematical Methods
            Unit 3 SAC 2: Data analysis
            Date of task: Thursday 12 November 2026
            This SAC is worth 10% of your study score.
            """)?.assessment)
        #expect(found.title == "Unit 3 SAC 2: Data analysis")
        #expect(found.weighting == 10)
        #expect(calendar.isDate(found.due, inSameDayAs: calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!))
    }

    @Test func aPresentationIsRecognised() throws {
        let found = try #require(read("""
            English Advanced
            Assessment Task 3: Multimodal presentation
            Due: Monday 2 November 2026
            25% of the course mark
            """)?.assessment)
        #expect(found.kind == .presentation)
        #expect(found.weighting == 25)
    }

    @Test func markingCriteriaAreRecognised() {
        let reading = read("""
            Marking criteria
            Task 2: Depth Study
            A – Designs a valid and reliable investigation
            """)
        #expect(reading?.role == .criteria)
        #expect(reading?.assessment == nil)
    }

    @Test func returnedWorkGivesItsMark() throws {
        let reading = try #require(read("""
            Depth Study – Enzymes
            Feedback
            Mark: 18/25
            Grade: B+
            Your method was clear; improve your discussion of errors.
            """))
        #expect(reading.role == .returned)
        #expect(reading.mark == Assessment.Mark(score: 18, outOf: 25, grade: "B+"))
    }

    @Test func pastPapersAreLeftOut() {
        let reading = read(
            "2023 HSC Biology Marking Guidelines\nQuestion 21 (5 marks)\nCriteria",
            facets: Facets(documentType: "Past Papers", year: 2023, exam: "HSC")
        )
        #expect(reading == nil)
    }

    @Test func plainNotesSayNothing() {
        #expect(read("Enzymes are biological catalysts. The rate of reaction depends on temperature and pH.") == nil)
    }

    @Test func anyDueDateIsStillOffered() throws {
        let reading = try #require(read("Chapter 4 questions\nHomework due: Tuesday 20 October 2026"))
        #expect(reading.assessment?.kind == .task)
        #expect(reading.role == nil)
    }

    @Test func aFileThatNamesAnOpenAssessmentIsOfferedAsALink() throws {
        let study = Assessment(title: "Depth Study – Investigating Enzymes", subjectID: UUID(), due: now.addingTimeInterval(86_400 * 20))
        let generic = Assessment(title: "Task 2", subjectID: study.subjectID, due: now.addingTimeInterval(86_400 * 20))
        let reading = try #require(read("My draft for the Depth Study – Investigating Enzymes.\nIntroduction…", name: "Enzymes draft.docx", open: [study, generic]))
        #expect(reading.mentioned == study.id)
        #expect(reading.role == .resource)
    }

    @Test func shortTitlesAreTooCommonToMatch() {
        #expect(!AssessmentReader.isDistinctive("Task 2"))
        #expect(!AssessmentReader.isDistinctive("Assessment task"))
        #expect(AssessmentReader.isDistinctive("Depth Study"))
    }

    @Test func weightingsAreReadInTheirUsualForms() {
        #expect(AssessmentReader.weighting(in: "weighting: 25%") == 25)
        #expect(AssessmentReader.weighting(in: "this task is worth 40% of your final mark") == 40)
        #expect(AssessmentReader.weighting(in: "15 % of the course") == 15)
        #expect(AssessmentReader.weighting(in: "accuracy within 5% of the true value") == nil)
    }
}
