import AppKit
import Foundation
import NaturalLanguage
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Reads a file into `Evidence`. Everything runs on this Mac.
public struct Extractor: Sendable {
    public enum ExtractionError: Error {
        case unreadable
    }

    /// How many PDF pages are read.
    public var maxPages = 3
    /// The longest text excerpt kept.
    public var maxCharacters = 4000
    /// PDFs with less embedded text than this are treated as scans and read with OCR.
    public var minimumEmbeddedText = 120
    /// How many pages of a scan are read with OCR, which takes about a quarter of a second a page.
    public var maxScannedPages = 2
    /// How much of a recording or video is listened to. A lesson's subject is
    /// usually clear in the first few minutes, and transcribing runs at about
    /// 20 times real time on an M1.
    public var listeningSeconds: TimeInterval = 180
    /// How long to wait for a file in iCloud Drive to download before sorting it by its name.
    public var iCloudWait: Duration = .seconds(120)
    /// The longest a file takes to read before Folio gives up on it. Reading
    /// uses system services for text in images, speech and previews, and one
    /// that never answers would otherwise hold up every file after it.
    public var timeLimit: Duration = .seconds(600)

    public init() {}

    /// Reads much more of a file: for writing flashcards and summaries rather than sorting.
    public static var thorough: Extractor {
        var extractor = Extractor()
        extractor.maxPages = 40
        extractor.maxCharacters = 40_000
        extractor.maxScannedPages = 10
        extractor.listeningSeconds = 30 * 60
        extractor.timeLimit = .seconds(900)
        return extractor
    }

    /// Reads `url`. `progress` hears short updates such as "Reading 3 pages…".
    /// Throws `AIDeadline.Exceeded` when reading takes longer than `timeLimit`.
    public func extract(from url: URL, progress: (@Sendable (String) -> Void)? = nil) async throws -> Evidence {
        try await AIDeadline.run(within: timeLimit) { [self] in
            try await read(url, progress: progress)
        }
    }

    private func read(_ url: URL, progress: (@Sendable (String) -> Void)?) async throws -> Evidence {
        let isDownloaded = await downloadFromICloudIfNeeded(url, progress: progress)
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        var evidence = Evidence(
            fileName: url.lastPathComponent,
            folderName: url.deletingLastPathComponent().lastPathComponent,
            contentType: type.identifier,
            sourceURLs: FileMetadata.downloadSources(of: url),
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            arrived: FileMetadata.downloadedDate(of: url) ?? values?.addedToDirectoryDate ?? values?.creationDate
        )

        var text = ""
        if !isDownloaded {
            // Still in iCloud: sort it by its name and details.
        } else if type.conforms(to: .pdf) {
            let pdf = try await readPDF(at: url, progress: progress)
            (text, evidence.title, evidence.pageCount, evidence.method) = (pdf.text, pdf.title, pdf.pageCount, pdf.method)
        } else if type.conforms(to: .image) {
            progress?(String(localized: "Reading the text in the image…", bundle: .module))
            text = try await TextRecognizer.text(inImageAt: url)
            evidence.method = .recognisedText
            evidence.imageURL = url
        } else if type.conforms(to: .plainText) && !type.conforms(to: .html) {
            text = Self.readPlainText(at: url)
            evidence.method = .embeddedText
        } else if let documentType = Self.documentType(for: type) {
            progress?(String(localized: "Reading the document…", bundle: .module))
            let document = try await Self.readDocument(at: url, as: documentType)
            (text, evidence.title) = (document.text, document.title)
            evidence.method = .embeddedText
        } else if type.conforms(to: .audiovisualContent) {
            evidence.duration = await MediaReader.duration(of: url)
            var parts: [String] = []
            if type.conforms(to: .movie) {
                progress?(String(localized: "Reading the text on screen…", bundle: .module))
                parts.append(await MediaReader.onScreenText(of: url))
            }
            // A recording that can't be transcribed is still sorted by its name and any text on screen.
            parts.append((try? await MediaReader.transcript(of: url, limit: listeningSeconds, progress: progress)) ?? "")
            text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
            evidence.method = text.isEmpty ? .metadataOnly : .transcribed
        } else {
            progress?(String(localized: "Reading a preview of the file…", bundle: .module))
            if let preview = try? await previewText(of: url) {
                text = preview
                evidence.method = .previewText
            }
        }

        evidence.text = Self.tidy(text, limit: maxCharacters)
        if evidence.text.count >= 20 {
            evidence.language = NLLanguageRecognizer.dominantLanguage(for: evidence.text)?.rawValue
        }
        return evidence
    }

    // MARK: iCloud

    /// Starts downloading a file that's only in iCloud and waits for it.
    /// Returns `false` if it didn't arrive in time.
    private func downloadFromICloudIfNeeded(_ url: URL, progress: (@Sendable (String) -> Void)?) async -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current
        else { return true }

        progress?(String(localized: "Downloading from iCloud…", bundle: .module))
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = ContinuousClock.now + iCloudWait
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(1))
            var fresh = url
            fresh.removeAllCachedResourceValues()
            if (try? fresh.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus == .current {
                return true
            }
        }
        return false
    }

    // MARK: PDF

    private func readPDF(at url: URL, progress: (@Sendable (String) -> Void)?) async throws -> (text: String, title: String?, pageCount: Int, method: ExtractionMethod) {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable }
        let pageCount = document.pageCount
        guard !document.isLocked else { return ("", nil, pageCount, .metadataOnly) }
        let pagesRead = min(maxPages, pageCount)
        switch (pagesRead, pageCount) {
        case let (read, total) where read == total: progress?(String(localized: "Reading \(total) pages…", bundle: .module))
        case let (read, total): progress?(String(localized: "Reading the first \(read) of \(total) pages…", bundle: .module))
        }

        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let embedded = (0..<pagesRead)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        if embedded.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumEmbeddedText {
            return (embedded, title, pageCount, .embeddedText)
        }

        // Little or no text layer: probably a scan, so read the first pages with OCR.
        let images = (0..<min(maxScannedPages, pageCount)).compactMap { document.page(at: $0).flatMap(Self.image(of:)) }
        var recognised = ""
        for (number, image) in images.enumerated() {
            progress?(String(localized: "Reading scanned page \(number + 1) of \(images.count)…", bundle: .module))
            recognised += try await TextRecognizer.text(in: image) + "\n"
        }
        return recognised.count > embedded.count
            ? (recognised, title, pageCount, .recognisedText)
            : (embedded, title, pageCount, .embeddedText)
    }

    private static func image(of page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 1600 / max(bounds.width, bounds.height)
        let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Documents

    private static func documentType(for type: UTType) -> NSAttributedString.DocumentType? {
        switch type.identifier {
        case "org.openxmlformats.wordprocessingml.document": .officeOpenXML
        case "com.microsoft.word.doc": .docFormat
        case "org.oasis-open.opendocument.text": .openDocument
        case UTType.rtf.identifier: .rtf
        case UTType.rtfd.identifier, UTType.flatRTFD.identifier: .rtfd
        case UTType.html.identifier: .html
        case UTType.webArchive.identifier: .webArchive
        default: nil
        }
    }

    private static func readDocument(at url: URL, as documentType: NSAttributedString.DocumentType) async throws -> (text: String, title: String?) {
        let read = { () throws -> (String, String?) in
            var attributes: NSDictionary?
            let string = try NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: &attributes)
            let title = attributes?[NSAttributedString.DocumentAttributeKey.title] as? String
            return (string.string, title.flatMap { $0.isEmpty ? nil : $0 })
        }
        // AppKit's HTML and web archive readers must run on the main thread.
        if documentType == .html || documentType == .webArchive {
            return try await MainActor.run { try read() }
        }
        return try read()
    }

    private static func readPlainText(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Anything else

    /// Slides, Pages and Keynote files and other types: read the text in a Quick Look preview.
    private func previewText(of url: URL) async throws -> String {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 1600, height: 1600),
            scale: 1,
            representationTypes: .thumbnail
        )
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return try await TextRecognizer.text(in: representation.cgImage)
    }

    /// Normalises line endings and spacing, drops blank lines and control
    /// characters, and keeps at most `limit` characters.
    static func tidy(_ text: String, limit: Int) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { line in
                String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(limit))
    }
}
