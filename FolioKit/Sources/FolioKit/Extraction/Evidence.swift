import Foundation

/// What Folio could read from a file. Every voter works from this.
public struct Evidence: Hashable, Codable, Sendable {
    public var fileName: String
    /// The name of the folder the file was in.
    public var folderName: String?
    /// The file's type, such as "com.adobe.pdf".
    public var contentType: String
    /// A title from the document's own metadata, when it has one.
    public var title: String?
    /// The start of the file's text, tidied up and shortened.
    public var text: String
    public var pageCount: Int?
    /// Where the file was downloaded from, as macOS recorded it.
    public var sourceURLs: [String]
    /// The main language of the text, such as "fr".
    public var language: String?
    public var created: Date?
    public var modified: Date?
    /// How the text was read.
    public var method: ExtractionMethod
    /// How long a recording or video is, in seconds.
    public var duration: Double?
    /// The file itself when it's a photo or other image, so the on-device AI can look at it.
    public var imageURL: URL?
    /// When it arrived: downloaded, or added to its folder.
    public var arrived: Date?

    public init(
        fileName: String,
        folderName: String? = nil,
        contentType: String,
        title: String? = nil,
        text: String = "",
        pageCount: Int? = nil,
        sourceURLs: [String] = [],
        language: String? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        method: ExtractionMethod = .metadataOnly,
        duration: Double? = nil,
        imageURL: URL? = nil,
        arrived: Date? = nil
    ) {
        self.fileName = fileName
        self.folderName = folderName
        self.contentType = contentType
        self.title = title
        self.text = text
        self.pageCount = pageCount
        self.sourceURLs = sourceURLs
        self.language = language
        self.created = created
        self.modified = modified
        self.method = method
        self.duration = duration
        self.imageURL = imageURL
        self.arrived = arrived
    }

    /// The file name without its extension, with `_`, `-` and `.` turned into spaces.
    public var readableFileName: String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.replacing(/[_\-.]+/, with: " ")
    }

    /// The website the file came from, such as "educationstandards.nsw.edu.au".
    public var sourceHost: String? {
        sourceURLs.lazy.compactMap { URL(string: $0)?.host() }.first
    }
}

public enum ExtractionMethod: String, Codable, Sendable {
    /// Text stored in the file: a PDF's text layer, a Word document, plain text.
    case embeddedText
    /// Text recognised in an image or in scanned pages.
    case recognisedText
    /// Text recognised in a Quick Look preview of the file.
    case previewText
    /// Words spoken in a recording or video, and text on screen in a video.
    case transcribed
    /// Only the file name and metadata could be read.
    case metadataOnly
}
