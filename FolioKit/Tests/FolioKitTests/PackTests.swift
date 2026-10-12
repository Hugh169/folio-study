import Foundation
import Testing
@testable import FolioKit

struct PackLibraryTests {
    @Test func everyPackAndTopicLoads() {
        #expect(PackLibrary.topics.count >= 40)
        let ids = Set(PackLibrary.packs.map(\.id))
        #expect(ids == ["au-nsw-hsc", "au-vic-vce", "au-qld-qce", "au-wa-wace", "au-sa-sace", "uk-gcse-alevel", "ib-diploma", "us-hs-ap", "cambridge-intl", "university", "other"])
    }

    @Test(arguments: PackLibrary.packs) func packsHaveNoProblems(_ pack: CurriculumPack) {
        #expect(PackLibrary.problems(in: pack) == [])
        #expect(pack.lastChecked != nil)
        if pack.level == .school {
            #expect(pack.suggested.count >= 5)
            #expect(pack.chipCourses.count >= 12)
        }
    }

    @Test func everyTopicHasEnoughWordsAndAName() {
        for topic in PackLibrary.topics.values {
            #expect(Set(topic.keywords.map { $0.lowercased() }).count >= 15, "\(topic.id)")
            #expect(!topic.summary.isEmpty, "\(topic.id)")
        }
    }

    @Test func theOriginalSubjectsKeepTheirWords() {
        for subject in Profile.starter().subjects {
            let topic = PackLibrary.topics[subject.name.lowercased()]
            #expect(topic?.keywords == subject.keywords, "\(subject.name)")
            #expect(topic?.summary == subject.summary, "\(subject.name)")
        }
    }

    @Test func theMacsRegionComesFirst() {
        #expect(PackLibrary.groups(for: "AU").first?.name == "Australia")
        #expect(PackLibrary.groups(for: "GB").first?.name == "United Kingdom")
        #expect(PackLibrary.groups(for: "US").first?.name == "United States")
        let last = PackLibrary.groups(for: "AU").last?.packs.map(\.id)
        #expect(last == ["university", "other"])
    }
}

struct CurriculumPackTests {
    let hsc = PackLibrary.pack("au-nsw-hsc")!

    @Test func theHSCHasItsCurrentCourses() {
        for name in ["Mathematics Advanced", "Mathematics Extension 2", "English Advanced", "English EAL/D", "Software Engineering", "Enterprise Computing", "Health and Movement Science", "Studies of Religion II", "Japanese In Context"] {
            #expect(hsc.subjects.contains { $0.name == name }, "\(name)")
        }
        #expect(hsc.suggestedCourses.map(\.name) == ["English Advanced", "Mathematics Advanced", "Physics", "Chemistry", "Modern History"])
    }

    @Test func foldersFindTheirCourse() {
        #expect(hsc.course(named: "Maths Ext 1")?.id == "maths-ext1")
        #expect(hsc.course(named: "PDHPE")?.id == "health-movement-science")
        #expect(hsc.course(named: "bio")?.id == "biology")
        #expect(hsc.course(named: "Biologie")?.id == "biology")
        #expect(hsc.course(named: "chemistry ")?.id == "chemistry")
        #expect(hsc.course(named: "Old timetables") == nil)
        // A topic's name gives the course most students take.
        #expect(hsc.course(named: "Maths")?.id == "maths-advanced")
        #expect(hsc.course(named: "History")?.id == "modern-history")
        // Everyday words still find a folder, though they don't count in files.
        #expect(hsc.course(named: "Law")?.id == "legal-studies")
        #expect(hsc.course(named: "Art")?.id == "visual-arts")
        let uk = PackLibrary.pack("uk-gcse-alevel")!
        #expect(uk.course(named: "8461")?.id == "biology")
    }

    @Test func aCourseBecomesASubjectWithItsTopicsWords() {
        let course = hsc.course("maths-ext1")!
        let subject = hsc.subject(for: course, colorHex: 0x0A84FF)
        #expect(subject.name == "Mathematics Extension 1")
        #expect(subject.topic == "mathematics")
        #expect(subject.aliases.contains("3U Maths"))
        #expect(subject.aliases.contains("Maths"))
        // Names in other languages only find folders.
        #expect(!subject.aliases.contains("Mathématiques"))
        #expect(subject.keywords.contains("calculus"))
        #expect(subject.keywords.contains("mathematical induction"))
        #expect(subject.summary == PackLibrary.topics["mathematics"]?.summary)
        let french = hsc.subject(for: hsc.course("french-continuers")!, colorHex: 0)
        #expect(french.languageOfStudy == "fr")
    }

    @Test func aPackBuildsAProfile() {
        let subjects = hsc.suggestedCourses.map { hsc.subject(for: $0, colorHex: 0) }
        let profile = hsc.profile(subjects: subjects)
        #expect(profile.packID == "au-nsw-hsc")
        #expect(profile.language == "en")
        #expect(profile.level == .school)
        #expect(profile.documentTypes.map(\.name).contains("Assessment Tasks"))
        #expect(profile.documentTypes.contains { $0.name == "Recordings" && !$0.fileKinds.isEmpty })
        #expect(profile.studyPreferences.schoolHours == SchoolHours(start: 8 * 60 + 45, end: 15 * 60 + 15))
        #expect(profile.examBoards.map(\.name) == ["HSC"])

        let university = PackLibrary.pack("university")!.profile(subjects: [])
        #expect(university.level == .university)
        #expect(university.studyPreferences.schoolHours == nil)
    }

    @Test func termNames() throws {
        let calendar = Calendar(identifier: .gregorian)
        let october = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)))
        let march = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 1)))
        #expect(TermStyle.calendarYear.nextName(after: october, calendar: calendar) == "2027")
        #expect(TermStyle.calendarYear.nextName(after: march, calendar: calendar) == "2027")
        #expect(TermStyle.academicYear.nextName(after: october, calendar: calendar) == "2026–27")
        #expect(TermStyle.academicYear.nextName(after: march, calendar: calendar) == "2026–27")
        #expect(TermStyle.semesters.nextName(after: october, calendar: calendar) == "2027 Semester 1")
        #expect(TermStyle.fallSpring.nextName(after: october, calendar: calendar) == "Spring 2027")
        #expect(TermStyle.fallSpring.nextName(after: march, calendar: calendar) == "Fall 2027")
        #expect(TermStyle.regional.nextName(after: october, calendar: calendar, region: "AU") == "2027 Semester 1")
        #expect(TermStyle.regional.nextName(after: october, calendar: calendar, region: "US") == "Spring 2027")
        #expect(TermStyle.regional.nextName(after: october, calendar: calendar, region: "GB") == "2026–27")
    }

    @Test func sharedPacksLeaveOutPersonalSettings() throws {
        var profile = hsc.profile(subjects: hsc.suggestedCourses.map { hsc.subject(for: $0, colorHex: 0) })
        profile.studentName = "Sam"
        profile.rules = [SortingRule(field: .fileName, contains: "MATH1131", subjectID: profile.subjects[1].id)]
        let shared = PackLibrary.pack(from: profile, name: "Year 12 at Sam's school")
        let data = try PackLibrary.encode(shared)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("Sam\""))
        #expect(!text.contains("MATH1131"))
        let back = try PackLibrary.decode(data)
        #expect(back.subjects.map(\.name) == profile.subjects.map(\.name))
        #expect(back.subjects.first?.keywords.contains("poetry") == true)
        #expect(PackLibrary.problems(in: back) == [])
        // Imported subjects keep their words even without the shared topic library.
        let again = back.subject(for: back.subjects[1], colorHex: 0, topics: [:])
        #expect(again.keywords.contains("calculus"))
    }

    @Test func handMadePacksLoadWithDefaults() throws {
        let json = #"{"id": "my-class", "name": "My class", "subjects": [{"id": "maths", "name": "Maths", "topic": "mathematics"}]}"#
        let pack = try PackLibrary.decode(Data(json.utf8))
        #expect(pack.level == .school)
        #expect(pack.termStyle == .calendarYear)
        #expect(pack.subjects.first?.aliases == [])
        #expect(PackLibrary.problems(in: pack).isEmpty)
    }

    @Test func olderSettingsLoadIntoVersion4() throws {
        let json = #"{"version": 3, "subjects": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Biology"}]}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8)).migrated()
        #expect(profile.version == 4)
        #expect(profile.packID == nil)
        #expect(profile.studentName == nil)
        #expect(profile.subjects.first?.topic == nil)
    }
}

struct PackMatchingTests {
    @Test func prefixCodesMatchExamComponentCodes() {
        #expect(TermMatcher.count(of: "8461", in: "aqa 84611h qp jun22", extraCharacters: 3) == 1)
        #expect(TermMatcher.count(of: "8461", in: "aqa 84611h qp jun22") == 0)
        #expect(TermMatcher.count(of: "8461", in: "ref 846112345", extraCharacters: 3) == 0)
        #expect(TermMatcher.count(of: "0580", in: "0580 s23 qp 42") == 1)
    }

    @Test func chineseAndJapaneseWordsAreFoundWithoutSpaces() {
        #expect(TermMatcher.count(of: "化学", in: "我们学习化学反应和化学平衡") == 2)
        #expect(TermMatcher.count(of: "数学", in: "数学作业") == 1)
        #expect(TermMatcher.count(of: "ひらがな", in: "きょうはひらがなのれんしゅう") == 1)
        // Latin-script words still need whole-word matches.
        #expect(TermMatcher.count(of: "war", in: "software") == 0)
    }

    @Test func abbreviationsCountOnlyInCapitals() {
        #expect(TermMatcher.isAbbreviation("IT"))
        #expect(TermMatcher.isAbbreviation("EAL/D"))
        #expect(!TermMatcher.isAbbreviation("ToK"))
        #expect(!TermMatcher.isAbbreviation("SOR 1"))
        #expect(!TermMatcher.isAbbreviation("A"))
        #expect(TermMatcher.count(ofAbbreviation: "IT", in: "IT assignment", ignoringCapitalisedRuns: false) == 1)
        #expect(TermMatcher.count(ofAbbreviation: "IT", in: "Explain why it happens.", ignoringCapitalisedRuns: true) == 0)
        #expect(TermMatcher.count(ofAbbreviation: "IT", in: "Year 10 IT project", ignoringCapitalisedRuns: true) == 1)
        #expect(TermMatcher.count(ofAbbreviation: "IT", in: "DO NOT WRITE IT HERE", ignoringCapitalisedRuns: true) == 0)
        #expect(TermMatcher.count(ofAbbreviation: "PE", in: "PE NOTES", ignoringCapitalisedRuns: false) == 1)
    }

    @Test func everydayWordsAndOtherLanguagesDontPointToASubject() async {
        let other = PackLibrary.pack("other")!
        let profile = other.profile(subjects: ["physics", "legal-studies", "computer-science", "history"].compactMap { other.course($0) }.map { other.subject(for: $0, colorHex: 0) })
        #expect(profile.subjects.count == 4)
        let physics = Evidence(
            fileName: "Forces notes.docx",
            contentType: "org.openxmlformats.wordprocessingml.document",
            text: "Newton's laws of motion. The first law says it stays at rest unless a net force acts. The second law links force, mass and acceleration."
        )
        let vote = await KeywordVoter().vote(on: physics, profile: profile)
        #expect(vote.top?.id == profile.subject(named: "Physics")?.id)
        #expect(vote.scores[profile.subject(named: "Legal Studies")!.id] == nil)
        #expect(vote.scores[profile.subject(named: "Computer Science")!.id] == nil)

        // "Histoire" in a French worksheet is French class talking about school.
        let history = PackLibrary.pack("au-nsw-hsc")!.subject(for: PackLibrary.pack("au-nsw-hsc")!.course("modern-history")!, colorHex: 0)
        #expect(!history.aliases.contains("Histoire"))
    }

    @Test func aLongerPhraseWinsOverAWordInsideIt() async {
        let uk = PackLibrary.pack("uk-gcse-alevel")!
        let profile = uk.profile(subjects: ["chemistry", "law"].map { uk.subject(for: uk.course($0)!, colorHex: 0) })
        let chemistry = profile.subject(named: "Chemistry")!.id
        let law = profile.subject(named: "Law")!.id
        let notes = Evidence(
            fileName: "Enthalpy and Hess\u{2019}s law.docx",
            contentType: "org.openxmlformats.wordprocessingml.document",
            text: "Hess\u{2019}s law: the enthalpy change of a reaction is the same whichever route it takes."
        )
        let vote = await KeywordVoter().vote(on: notes, profile: profile)
        #expect(vote.top?.id == chemistry)
        #expect(vote.scores[law] == nil)

        // On its own, the word still counts.
        let essay = Evidence(fileName: "Essay.docx", contentType: "org.openxmlformats.wordprocessingml.document", text: "How well does the law protect consumers who buy online?")
        #expect(await KeywordVoter().vote(on: essay, profile: profile).top?.id == law)
    }

    @Test func anAQAPaperFindsItsSubjectByCode() async {
        let uk = PackLibrary.pack("uk-gcse-alevel")!
        let profile = uk.profile(subjects: ["biology", "chemistry", "history"].map { uk.subject(for: uk.course($0)!, colorHex: 0) })
        let paper = Evidence(fileName: "AQA-84611H-QP-JUN22.PDF", contentType: "com.adobe.pdf")
        let vote = await KeywordVoter().vote(on: paper, profile: profile)
        #expect(vote.top?.id == profile.subject(named: "Biology")?.id)
    }

    @Test func aFrenchWorksheetPointsToFrenchClass() async {
        let hsc = PackLibrary.pack("au-nsw-hsc")!
        let profile = hsc.profile(subjects: ["maths-advanced", "french-continuers", "modern-history"].map { hsc.subject(for: hsc.course($0)!, colorHex: 0) })
        let worksheet = Evidence(
            fileName: "Devoir 3.docx",
            contentType: "org.openxmlformats.wordprocessingml.document",
            text: "Complétez les phrases avec le verbe au présent. Ensuite, écrivez un paragraphe sur vos vacances et ce que vous aimez faire le week-end avec votre famille.",
            language: "fr"
        )
        let vote = await KeywordVoter().vote(on: worksheet, profile: profile)
        #expect(vote.top?.id == profile.subject(named: "French Continuers")?.id)
        #expect(vote.reasons.first?.hasPrefix("Written in") == true)

        // Someone taught in French isn't pushed towards a French course by French files.
        var french = profile
        french.language = "fr"
        #expect(await KeywordVoter().vote(on: worksheet, profile: french).reasons.contains { $0.hasPrefix("Written in") } == false)
    }

    @Test func examBoardFileNamesGiveTheKindOfDocument() {
        let cambridge = PackLibrary.pack("cambridge-intl")!.profile(subjects: [])
        func type(_ name: String, _ text: String = "", in profile: Profile) -> String? {
            FacetHeuristics.documentType(in: Evidence(fileName: name, contentType: "com.adobe.pdf", text: text), profile: profile)
        }
        #expect(type("0580_s23_qp_42.pdf", in: cambridge) == "Past Papers")
        #expect(type("0580_s23_ms_42.pdf", in: cambridge) == "Mark Schemes")
        #expect(type("0610_w22_er.pdf", in: cambridge) == "Mark Schemes")
        let uk = PackLibrary.pack("uk-gcse-alevel")!.profile(subjects: [])
        #expect(type("AQA-84611H-MS-JUN22.PDF", in: uk) == "Mark Schemes")
        #expect(type("1ma1-1h-que-20220520.pdf", in: uk) == "Past Papers")
        #expect(type("1ma1-1h-rms-20220825.pdf", in: uk) == "Mark Schemes")
        // "Ms" in a worksheet's text is a teacher, not a mark scheme.
        #expect(type("Fractions worksheet.pdf", "Ms Nguyen, Year 9. Worksheet: simplify each fraction.", in: uk) == "Worksheets")
        #expect(FacetHeuristics.looksLikeExam(type: "Mark Schemes", exam: nil))
    }
}
