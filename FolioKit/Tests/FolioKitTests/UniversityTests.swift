import Foundation
import Testing
@testable import FolioKit

struct UniversityTests {
    let comp = Subject(name: "COMP1511", colorHex: 0x0A84FF, aliases: ["Programming Fundamentals"], codes: ["COMP1511"], term: "2027 Semester 1")
    let math = Subject(name: "MATH1131", colorHex: 0xFF9F0A, aliases: ["Mathematics 1A"], codes: ["MATH1131"], term: "2027 Semester 1")
    var profile: Profile {
        var profile = Profile.university()
        profile.subjects = [comp, math]
        return profile
    }

    /// Monday 1 March 2027, 9 am.
    let lectureStart = Date(timeIntervalSinceReferenceDate: 794_008_800)

    func evidence(arrived: Date?) -> Evidence {
        Evidence(fileName: "slides.pdf", contentType: "com.adobe.pdf", text: "Week 1 slides", arrived: arrived)
    }

    var lecture: ClassSession {
        ClassSession(subjectID: comp.id, title: "COMP1511 Lecture", start: lectureStart, end: lectureStart.addingTimeInterval(2 * 3600))
    }

    @Test func aFileThatArrivedDuringALectureGetsItsVote() async {
        let voter = TimetableVoter(classes: [lecture])
        let vote = await voter.vote(on: evidence(arrived: lectureStart.addingTimeInterval(20 * 60)), profile: profile)
        #expect(vote.top?.id == comp.id)
        #expect(vote.reasons == ["Arrived during COMP1511 Lecture"])
    }

    @Test func justBeforeAndJustAfterCount() async {
        let voter = TimetableVoter(classes: [lecture])
        #expect(await voter.vote(on: evidence(arrived: lectureStart.addingTimeInterval(-10 * 60)), profile: profile).top?.id == comp.id)
        #expect(await voter.vote(on: evidence(arrived: lectureStart.addingTimeInterval(2 * 3600 + 25 * 60)), profile: profile).top?.id == comp.id)
        #expect(await voter.vote(on: evidence(arrived: lectureStart.addingTimeInterval(4 * 3600)), profile: profile).abstention != nil)
    }

    @Test func overlappingClassesMeanNoVote() async {
        let tutorial = ClassSession(subjectID: math.id, title: "MATH1131 Tutorial", start: lectureStart.addingTimeInterval(3600), end: lectureStart.addingTimeInterval(3 * 3600))
        let voter = TimetableVoter(classes: [lecture, tutorial])
        let vote = await voter.vote(on: evidence(arrived: lectureStart.addingTimeInterval(90 * 60)), profile: profile)
        #expect(vote.abstention?.reason == "Arrived while two classes were on")
    }

    @Test func archivedSubjectsGetNoVotes() async {
        var profile = profile
        profile.subjects[0].isArchived = true
        let voter = TimetableVoter(classes: [lecture])
        #expect(await voter.vote(on: evidence(arrived: lectureStart.addingTimeInterval(600)), profile: profile).abstention != nil)
    }

    @Test func timetableEventsAreMatchedToSubjects() {
        let events = [
            BusyBlock(id: "1", title: "COMP1511 Lecture", start: lectureStart, end: lectureStart.addingTimeInterval(7200), calendarID: "uni"),
            BusyBlock(id: "2", title: "MATH 1131 Tut", start: lectureStart, end: lectureStart.addingTimeInterval(3600), calendarID: "uni"),
            BusyBlock(id: "3", title: "Mathematics 1A help session", start: lectureStart, end: lectureStart.addingTimeInterval(3600), calendarID: "uni"),
            BusyBlock(id: "4", title: "Netball", start: lectureStart, end: lectureStart.addingTimeInterval(3600), calendarID: "uni"),
            BusyBlock(id: "5", title: "Census date", start: lectureStart, end: lectureStart.addingTimeInterval(86_400), isAllDay: true, calendarID: "uni"),
        ]
        let classes = TimetableReader.classes(from: events, subjects: [comp, math])
        #expect(classes.map(\.title) == ["COMP1511 Lecture", "MATH 1131 Tut", "Mathematics 1A help session"])
        #expect(classes.map(\.subjectID) == [comp.id, math.id, math.id])
    }

    @Test func termFoldersComeFromTheSubject() {
        let folders = FolderTemplate("{term}/{subject}/{type}").folders(for: comp, facets: Facets(documentType: "Lectures"))
        #expect(folders == ["2027 Semester 1", "COMP1511", "Lectures"])
    }

    @Test func archivedSubjectsAreLeftOutOfSorting() async {
        var profile = profile
        profile.subjects[0].isArchived = true
        let vote = await KeywordVoter().vote(on: Evidence(fileName: "COMP1511 week 2.pdf", contentType: "com.adobe.pdf", text: "Programming Fundamentals"), profile: profile)
        #expect(vote.top == nil)
        #expect(profile.subject(named: "COMP1511") == nil)
        #expect(profile.subject(comp.id)?.name == "COMP1511")
    }

    @Test func theUniversityProfileHasUniversityKinds() {
        let profile = Profile.university()
        #expect(profile.level == .university)
        #expect(profile.examBoards.isEmpty)
        #expect(profile.documentTypes.map(\.name).contains("Lectures"))
        #expect(profile.studyPreferences.schoolHours == nil)
        let lecture = Evidence(fileName: "COMP1511 Week 3 Lecture.pdf", contentType: "com.adobe.pdf", text: "Week 3: loops and arrays")
        #expect(FacetHeuristics.documentType(in: lecture, profile: profile) == "Lectures")
    }

    @Test func olderSettingsGainStudyPreferencesAndTerms() throws {
        let json = #"{"version": 2, "subjects": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Biology"}]}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8)).migrated()
        #expect(profile.version == Profile.currentVersion)
        #expect(profile.level == .school)
        #expect(profile.studyPreferences == StudyPreferences())
        #expect(profile.subjects.first?.isArchived == false)
        #expect(profile.subjects.first?.term == nil)
    }
}

struct ArrivalTests {
    @Test func theBrowsersDownloadDateIsWhenAFileArrived() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Downloads/slides.txt", contents: "Week 3 slides")
        let downloaded = Date(timeIntervalSinceReferenceDate: 794_010_000)
        let data = try PropertyListSerialization.data(fromPropertyList: [downloaded], format: .binary, options: 0)
        _ = data.withUnsafeBytes { setxattr(file.path, FileMetadata.downloadedDateAttribute, $0.baseAddress, data.count, 0, 0) }

        let evidence = try await Extractor().extract(from: file)

        #expect(evidence.arrived == downloaded)
    }

    @Test func otherwiseItsWhenTheFileWasAdded() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/notes.txt", contents: "Some notes")
        let evidence = try await Extractor().extract(from: file)
        #expect(abs((evidence.arrived ?? .distantPast).timeIntervalSinceNow) < 60)
    }
}
