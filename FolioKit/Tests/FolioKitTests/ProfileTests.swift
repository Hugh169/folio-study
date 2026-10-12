import Foundation
import Testing
@testable import FolioKit

struct ProfileTests {
    @Test func starterProfileSurvivesSavingAndLoading() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-tests-\(UUID().uuidString)/profile.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProfileStore(url: url)
        let profile = Profile.starter()

        try store.save(profile)

        #expect(try store.load() == profile)
    }

    @Test func missingProfileLoadsAsNil() throws {
        let store = ProfileStore(url: FileManager.default.temporaryDirectory.appending(path: "folio-missing-\(UUID().uuidString).json"))
        #expect(try store.load() == nil)
    }

    @Test func olderFilesWithMissingFieldsStillLoad() throws {
        let json = """
        {"subjects": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Biology"}]}
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))

        #expect(profile.version == Profile.currentVersion)
        #expect(profile.subjects.first?.name == "Biology")
        #expect(profile.subjects.first?.aliases == [])
        #expect(profile.folderTemplate == "{subject}/{type}")
        #expect(profile.autoFileLevel == .careful)
    }

    @Test func olderSettingsGainRecordingsAndVideos() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-v1-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version": 1, "subjects": [], "documentTypes": [{"name": "Notes", "aliases": ["notes"]}]}"#.utf8).write(to: url)

        let profile = try #require(try ProfileStore(url: url).load())

        #expect(profile.version == Profile.currentVersion)
        #expect(profile.documentTypes.map(\.name) == ["Notes", "Recordings", "Videos"])
    }

    @Test func recordingsAreFiledAsRecordings() {
        let memo = Evidence(fileName: "New Recording 12.m4a", contentType: "com.apple.m4a-audio", text: "notes for the essay")
        #expect(FacetHeuristics.documentType(in: memo, profile: .starter()) == "Recordings")
    }

    @Test func newerFilesAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-newer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version": 99, "subjects": []}"#.utf8).write(to: url)

        #expect(throws: ProfileStore.StoreError.newerVersion(99)) {
            try ProfileStore(url: url).load()
        }
    }

    @Test func subjectsCanBeFoundByAlias() {
        let profile = Profile.starter()
        #expect(profile.subject(named: "maths")?.name == "Mathematics")
        #expect(profile.subject(named: "Modern History")?.name == "History")
        #expect(profile.subject(named: "Biology") == nil)
    }
}
