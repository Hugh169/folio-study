import Foundation

/// A class the student takes, such as Mathematics. Everything that helps Folio
/// recognise its files lives here, so any student can describe their own subjects.
public struct Subject: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Used for the subject's dot, tinted file icons and planner blocks.
    public var colorHex: UInt32
    /// Other names the subject goes by: abbreviations, course names, translations.
    public var aliases: [String]
    /// Course or syllabus codes, such as "8464" for AQA GCSE Combined Science.
    public var codes: [String]
    /// One line describing what the subject covers. The on-device AI reads this.
    public var summary: String
    /// Topic words that point to this subject, such as "photosynthesis".
    public var keywords: [String]
    /// The subject's folder in the library, when it isn't named after the
    /// subject, such as "Maths" for Mathematics.
    public var folderName: String?
    /// The term it's taken in, such as "2027 Semester 1", for the "{term}" folder.
    public var term: String?
    /// From a past term: its folder stays, but Folio no longer files into it.
    public var isArchived: Bool
    /// The shared subject area it came from in a curriculum pack, such as "biology".
    public var topic: String?
    /// For a language course: the language studied, such as "fr". Files written
    /// in it point here when the student is taught in another language.
    public var languageOfStudy: String?
    /// The student's teachers or lecturers for it, as they'd write their names.
    public var teachers: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: UInt32,
        aliases: [String] = [],
        codes: [String] = [],
        summary: String = "",
        keywords: [String] = [],
        folderName: String? = nil,
        term: String? = nil,
        isArchived: Bool = false,
        topic: String? = nil,
        languageOfStudy: String? = nil,
        teachers: [String] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.aliases = aliases
        self.codes = codes
        self.summary = summary
        self.keywords = keywords
        self.folderName = folderName
        self.term = term
        self.isArchived = isArchived
        self.topic = topic
        self.languageOfStudy = languageOfStudy
        self.teachers = teachers
    }

    /// The name of the subject's folder: `folderName`, or else the subject's name.
    public var effectiveFolderName: String {
        guard let folderName, !folderName.trimmingCharacters(in: .whitespaces).isEmpty else { return name }
        return folderName
    }

    // Missing fields fall back to defaults, so older settings files still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decodeIfPresent(UInt32.self, forKey: .colorHex) ?? 0x8E8E93
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        codes = try container.decodeIfPresent([String].self, forKey: .codes) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName)
        term = try container.decodeIfPresent(String.self, forKey: .term)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        languageOfStudy = try container.decodeIfPresent(String.self, forKey: .languageOfStudy)
        teachers = try container.decodeIfPresent([String].self, forKey: .teachers) ?? []
    }
}
