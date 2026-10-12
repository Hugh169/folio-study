import Foundation
import Testing
@testable import FolioKit

/// A temporary folder that's deleted when the test ends.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "folio-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ path: String, contents: String = "Some text") throws -> URL {
        let file = url.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func folder(_ path: String) throws -> URL {
        let folder = url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: path).path(percentEncoded: false))
    }

    func contents(of path: String) throws -> String {
        try String(contentsOf: url.appending(path: path), encoding: .utf8)
    }
}

struct FolderTemplateTests {
    let history = Subject(name: "History", colorHex: 0xFF6482)

    @Test func standardTemplateFilesBySubjectThenType() {
        let folders = FolderTemplate.standard.folders(for: history, facets: Facets(documentType: "Past Papers", year: 2023))
        #expect(folders == ["History", "Past Papers"])
    }

    @Test func foldersWithUnknownDetailsAreSkipped() {
        let template = FolderTemplate("{subject}/{year}/{type}")
        #expect(template.folders(for: history, facets: Facets(documentType: "Notes")) == ["History", "Notes"])
        #expect(template.folders(for: history, facets: Facets()) == ["History"])
    }

    @Test func placeholdersCanSitInsideNamesAndIgnoreCase() {
        let template = FolderTemplate("Year 11/{Subject}/{exam} {year}")
        let folders = template.folders(for: history, facets: Facets(year: 2023, exam: "HSC"))
        #expect(folders == ["Year 11", "History", "HSC 2023"])
    }

    @Test func theSubjectsOwnFolderNameIsUsed() {
        let maths = Subject(name: "Mathematics", colorHex: 0, folderName: "Maths")
        #expect(FolderTemplate.standard.folders(for: maths, facets: Facets(documentType: "Notes")) == ["Maths", "Notes"])
    }

    @Test func namesAreMadeSafeForFolders() {
        #expect(FolderTemplate.cleanFolderName("  Physics: Waves/Optics  ") == "Physics- Waves-Optics")
        #expect(FolderTemplate.cleanFolderName(".hidden") == "hidden")
        #expect(FolderTemplate.cleanFolderName("Notes...") == "Notes")
        #expect(FolderTemplate.cleanFolderName("..") == "")
    }

    @Test func problemsAreReported() {
        #expect(FolderTemplate.standard.problem == nil)
        #expect(FolderTemplate("{type}").problem == .noSubjectFolder)
        #expect(FolderTemplate("{subject} {type}").problem == .subjectNotOnItsOwn)
        #expect(FolderTemplate("{subject}/{subject}").problem == .subjectNotOnItsOwn)
        #expect(FolderTemplate("{subject}/{teacher}").problem == .unknownPlaceholder("teacher"))
        #expect(FolderTemplate("../{subject}").problem == .invalidFolder(".."))
    }
}

struct OrganizerTests {
    @Test func filesIntoNewFoldersKeepingTheName() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/2023 HSC Modern History.pdf", contents: "paper")
        let organizer = Organizer(library: try temp.folder("School"))

        let move = try await organizer.file(file, into: ["History", "Past Papers"])

        #expect(move.to.lastPathComponent == "2023 HSC Modern History.pdf")
        #expect(temp.exists("School/History/Past Papers/2023 HSC Modern History.pdf"))
        #expect(!temp.exists("Desktop/2023 HSC Modern History.pdf"))
    }

    @Test func nameClashesGetANumberAndNothingIsReplaced() async throws {
        let temp = try TemporaryFolder()
        try temp.file("School/History/Notes/notes.pdf", contents: "first")
        let second = try temp.file("Desktop/notes.pdf", contents: "second")
        let third = try temp.file("Downloads/notes.pdf", contents: "third")
        let organizer = Organizer(library: temp.url.appending(path: "School"))

        _ = try await organizer.file(second, into: ["History", "Notes"])
        _ = try await organizer.file(third, into: ["History", "Notes"])

        #expect(try temp.contents(of: "School/History/Notes/notes.pdf") == "first")
        #expect(try temp.contents(of: "School/History/Notes/notes 2.pdf") == "second")
        #expect(try temp.contents(of: "School/History/Notes/notes 3.pdf") == "third")
    }

    @Test func aFileAlreadyInPlaceStaysPut() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("School/History/Notes/notes.pdf")
        let organizer = Organizer(library: temp.url.appending(path: "School"))

        let move = try await organizer.file(file, into: ["History", "Notes"])

        #expect(move.from == move.to)
        #expect(!temp.exists("School/History/Notes/notes 2.pdf"))
    }

    @Test func puttingBackReturnsTheFileToItsFolder() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/essay.docx")
        let organizer = Organizer(library: try temp.folder("School"))
        let move = try await organizer.file(file, into: ["English", "Essays"])

        let restored = try await organizer.putBack(move)

        #expect(restored.isOriginalFolder)
        #expect(temp.exists("Desktop/essay.docx"))
        #expect(!temp.exists("School/English/Essays/essay.docx"))
    }

    @Test func puttingBackDoesntReplaceANewFileWithTheSameName() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Desktop/essay.docx", contents: "old")
        let organizer = Organizer(library: try temp.folder("School"))
        let move = try await organizer.file(file, into: ["English"])
        try temp.file("Desktop/essay.docx", contents: "new")

        let restored = try await organizer.putBack(move)

        #expect(restored.url.lastPathComponent == "essay 2.docx")
        #expect(try temp.contents(of: "Desktop/essay.docx") == "new")
        #expect(try temp.contents(of: "Desktop/essay 2.docx") == "old")
    }

    @Test func puttingBackUsesFolioInboxWhenTheFolderIsGone() async throws {
        let temp = try TemporaryFolder()
        let file = try temp.file("Old Stuff/essay.docx")
        let organizer = Organizer(library: try temp.folder("School"))
        let move = try await organizer.file(file, into: ["English"])
        try FileManager.default.removeItem(at: temp.url.appending(path: "Old Stuff"))

        let restored = try await organizer.putBack(move)

        #expect(!restored.isOriginalFolder)
        #expect(temp.exists("School/Folio Inbox/essay.docx"))
    }

    @Test func aMissingFileIsReported() async throws {
        let temp = try TemporaryFolder()
        let organizer = Organizer(library: try temp.folder("School"))
        let ghost = temp.url.appending(path: "Desktop/ghost.pdf")

        await #expect(throws: Organizer.Failure.missing(ghost)) {
            try await organizer.file(ghost, into: ["History"])
        }
    }

    @Test func numberedNamesKeepTheExtension() {
        #expect(Organizer.numbered("notes.pdf", 1) == "notes.pdf")
        #expect(Organizer.numbered("notes.pdf", 2) == "notes 2.pdf")
        #expect(Organizer.numbered("Notes", 3) == "Notes 3")
    }
}

struct LibraryScannerTests {
    let profile = Profile.starter()
    var history: Subject { profile.subject(named: "History")! }
    var physics: Subject { profile.subject(named: "Physics")! }

    @Test func countsFilesBySubjectAndFolder() throws {
        let temp = try TemporaryFolder()
        try temp.file("School/History/Past Papers/2023.pdf")
        try temp.file("School/History/Past Papers/2022.pdf")
        try temp.file("School/History/Notes/cold war.docx")
        try temp.file("School/History/loose.pdf")
        try temp.file("School/History/.DS_Store")
        _ = try temp.folder("School/Physics/Practicals")
        try temp.file("School/Physics/Notes/Waves.rtfd/TXT.rtf")
        try temp.file("School/Holidays/beach.jpg")

        let snapshot = LibraryScanner.scan(temp.url.appending(path: "School"), template: .standard, subjects: profile.subjects)

        #expect(snapshot.fileCount(of: history.id) == 4)
        #expect(snapshot.folders[history.id]?.map(\.name) == ["Past Papers", "Notes"])
        #expect(snapshot.folders[history.id]?.first?.fileCount == 2)
        #expect(snapshot.looseFileCounts[history.id] == 1)
        // The RTFD package counts as one file, and the empty Practicals folder still shows.
        #expect(snapshot.fileCount(of: physics.id) == 1)
        #expect(snapshot.folders[physics.id]?.map(\.name) == ["Notes", "Practicals"])
        #expect(!snapshot.files.contains { $0.name == "beach.jpg" })
    }

    @Test func followsTemplatesWithFoldersBeforeTheSubject() throws {
        let temp = try TemporaryFolder()
        try temp.file("School/2025/History/Notes/a.pdf")
        try temp.file("School/2026/History/Notes/b.pdf")
        try temp.file("School/2026/History/Essays/c.pdf")

        let snapshot = LibraryScanner.scan(temp.url.appending(path: "School"), template: FolderTemplate("{year}/{subject}/{type}"), subjects: profile.subjects)

        #expect(snapshot.fileCount(of: history.id) == 3)
        #expect(snapshot.folders[history.id]?.first { $0.name == "Notes" }?.fileCount == 2)
    }

    @Test func matchesTheSubjectsFolderName() throws {
        let temp = try TemporaryFolder()
        try temp.file("School/Maths/Notes/a.pdf")
        var maths = profile.subject(named: "Mathematics")!
        maths.folderName = "Maths"

        let snapshot = LibraryScanner.scan(temp.url.appending(path: "School"), template: .standard, subjects: [maths])

        #expect(snapshot.fileCount(of: maths.id) == 1)
    }
}
