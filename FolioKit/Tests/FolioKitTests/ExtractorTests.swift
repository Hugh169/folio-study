import AppKit
import Foundation
import Testing
@testable import FolioKit
import FolioTestSupport

struct ExtractorTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "folio-extractor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    let body = """
    Photosynthesis converts light energy into chemical energy. In the chloroplasts, \
    chlorophyll absorbs light and water molecules are split, releasing oxygen. \
    The Calvin cycle then fixes carbon dioxide into glucose.
    """

    @Test func readsPlainText() async throws {
        let url = folder.appending(path: "notes.txt")
        try DocumentRenderer.writePlainText(title: "Biology notes", body: body, to: url)

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.text.contains("Calvin cycle"))
        #expect(evidence.method == .embeddedText)
        #expect(evidence.language == "en")
    }

    @Test(arguments: [("docx", NSAttributedString.DocumentType.officeOpenXML), ("rtf", .rtf)])
    func readsWordAndRTF(fileExtension: String, type: NSAttributedString.DocumentType) async throws {
        let url = folder.appending(path: "essay.\(fileExtension)")
        try DocumentRenderer.writeDocument(title: "Photosynthesis", body: body, to: url, as: type)

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.text.contains("chloroplasts"))
        #expect(evidence.method == .embeddedText)
    }

    @Test func readsAPDFTextLayer() async throws {
        let url = folder.appending(path: "worksheet.pdf")
        try DocumentRenderer.writePDF(title: "Year 11 Biology Worksheet", body: body, to: url)

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.text.contains("Year 11 Biology Worksheet"))
        #expect(evidence.pageCount == 1)
        #expect(evidence.method == .embeddedText)
    }

    @Test func readsAScannedPDFWithOCR() async throws {
        let url = folder.appending(path: "scan0007.pdf")
        try DocumentRenderer.writePDF(title: "Year 11 Biology Worksheet", body: body, to: url, scanned: true)

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.method == .recognisedText)
        #expect(evidence.text.localizedCaseInsensitiveContains("photosynthesis"))
    }

    @Test func readsHandwrittenNotesInAPhoto() async throws {
        let url = folder.appending(path: "IMG_4021.jpg")
        try DocumentRenderer.writeHandwrittenPhoto(title: "Photosynthesis", body: "Light energy is converted into chemical energy in the chloroplasts.", to: url, seed: 3)

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.method == .recognisedText)
        #expect(evidence.text.localizedCaseInsensitiveContains("chloroplast"))
    }

    @Test func readsWhereAFileWasDownloadedFrom() async throws {
        let url = folder.appending(path: "2023-hsc-modern-history.pdf")
        try DocumentRenderer.writePDF(title: "2023 HSC Modern History", body: body, to: url)
        let sources = ["https://www.educationstandards.nsw.edu.au/papers/2023-hsc-modern-history.pdf", "https://www.educationstandards.nsw.edu.au/"]
        let data = try PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0)
        _ = data.withUnsafeBytes { setxattr(url.path, FileMetadata.whereFromsAttribute, $0.baseAddress, data.count, 0, 0) }

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.sourceURLs == sources)
        #expect(evidence.sourceHost == "www.educationstandards.nsw.edu.au")
    }

    @Test func transcribesARecording() async throws {
        let url = folder.appending(path: "New Recording 12.m4a")
        try await MediaRenderer.writeRecording("Today we're revising photosynthesis. Chlorophyll in the chloroplasts absorbs light energy.", to: url)

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.method == .transcribed)
        #expect(evidence.text.localizedCaseInsensitiveContains("photosynthesis"))
        #expect((evidence.duration ?? 0) > 2)
        #expect(evidence.imageURL == nil)
    }

    @Test func readsTheSlidesAndSpeechInAVideo() async throws {
        let url = folder.appending(path: "IMG_5521.MOV")
        try await MediaRenderer.writeVideo(title: "The Calvin cycle", body: "Carbon dioxide is fixed into glucose. This happens in the stroma of the chloroplast.", to: url)

        let evidence = try await Extractor().extract(from: url)

        #expect(evidence.method == .transcribed)
        #expect(evidence.text.contains("Calvin cycle"))
        #expect(evidence.text.localizedCaseInsensitiveContains("glucose"))
    }

    @Test func photosCanBeShownToTheAI() async throws {
        let url = folder.appending(path: "IMG_4021.jpg")
        try DocumentRenderer.writeHandwrittenPhoto(title: "Waves", body: "Wavelength and frequency", to: url, seed: 1)
        #expect(try await Extractor().extract(from: url).imageURL == url)
    }

    @Test func tidiesWhitespaceAndLimitsLength() {
        let messy = "Line  one\r\n\r\n\tLine\u{0} two  \n   \nLine three"
        #expect(Extractor.tidy(messy, limit: 100) == "Line one\nLine two\nLine three")
        #expect(Extractor.tidy(messy, limit: 8) == "Line one")
    }

    @Test func readableFileNameDropsSeparators() {
        let evidence = Evidence(fileName: "2023_HSC-modern.history.pdf", contentType: "com.adobe.pdf")
        #expect(evidence.readableFileName == "2023 HSC modern history")
    }
}
