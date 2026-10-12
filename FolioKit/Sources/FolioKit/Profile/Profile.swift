import Foundation

/// Everything a student sets up: their subjects, the kinds of documents they
/// keep, the exams they sit, their own rules, and how sure Folio must be before
/// filing on its own. Saved as JSON so it can be exported and shared.
public struct Profile: Codable, Sendable, Equatable {
    /// 2 added document types matched by kind of file, such as Recordings.
    /// 3 added study preferences, school or university, and terms for subjects.
    /// 4 added the curriculum pack, the language it's taught in, the student's
    /// name, and a school timetable.
    public static let currentVersion = 4

    public var version: Int
    public var subjects: [Subject]
    public var documentTypes: [DocumentType]
    public var examBoards: [ExamBoard]
    /// Used when nothing in a file says what kind of document it is.
    public var defaultDocumentType: String?
    /// Where filed files go inside the library folder, such as "{subject}/{type}".
    public var folderTemplate: String
    public var rules: [SortingRule]
    public var autoFileLevel: AutoFileLevel
    public var level: StudyLevel
    public var studyPreferences: StudyPreferences
    /// The curriculum pack setup started from, such as "au-nsw-hsc".
    public var packID: String?
    /// The language the student is taught in, such as "en".
    public var language: String?
    /// What Folio calls the student, if they said. Kept on this Mac.
    public var studentName: String?
    /// The student's school timetable, if they entered one.
    public var timetable: SchoolTimetable?

    public init(
        subjects: [Subject],
        documentTypes: [DocumentType],
        examBoards: [ExamBoard],
        defaultDocumentType: String? = nil,
        folderTemplate: String = "{subject}/{type}",
        rules: [SortingRule] = [],
        autoFileLevel: AutoFileLevel = .careful,
        level: StudyLevel = .school,
        studyPreferences: StudyPreferences = StudyPreferences()
    ) {
        self.version = Self.currentVersion
        self.subjects = subjects
        self.documentTypes = documentTypes
        self.examBoards = examBoards
        self.defaultDocumentType = defaultDocumentType
        self.folderTemplate = folderTemplate
        self.rules = rules
        self.autoFileLevel = autoFileLevel
        self.level = level
        self.studyPreferences = studyPreferences
    }

    // Missing fields fall back to defaults, so older settings files still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        subjects = try container.decodeIfPresent([Subject].self, forKey: .subjects) ?? []
        documentTypes = try container.decodeIfPresent([DocumentType].self, forKey: .documentTypes) ?? []
        examBoards = try container.decodeIfPresent([ExamBoard].self, forKey: .examBoards) ?? []
        defaultDocumentType = try container.decodeIfPresent(String.self, forKey: .defaultDocumentType)
        folderTemplate = try container.decodeIfPresent(String.self, forKey: .folderTemplate) ?? "{subject}/{type}"
        rules = try container.decodeIfPresent([SortingRule].self, forKey: .rules) ?? []
        autoFileLevel = try container.decodeIfPresent(AutoFileLevel.self, forKey: .autoFileLevel) ?? .careful
        level = try container.decodeIfPresent(StudyLevel.self, forKey: .level) ?? .school
        studyPreferences = try container.decodeIfPresent(StudyPreferences.self, forKey: .studyPreferences) ?? StudyPreferences()
        packID = try container.decodeIfPresent(String.self, forKey: .packID)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        studentName = try container.decodeIfPresent(String.self, forKey: .studentName)
        timetable = try container.decodeIfPresent(SchoolTimetable.self, forKey: .timetable)
    }

    /// Brings a profile saved by an earlier version of Folio up to date.
    public func migrated() -> Profile {
        var profile = self
        if profile.version < 2, !profile.documentTypes.contains(where: { !$0.fileKinds.isEmpty }) {
            let names = Set(profile.documentTypes.map { $0.name.lowercased() })
            profile.documentTypes += Self.mediaDocumentTypes.filter { !names.contains($0.name.lowercased()) }
        }
        profile.version = Self.currentVersion
        return profile
    }

    /// Subjects Folio can file into: archived ones from past terms are left out.
    public var sortableSubjects: [Subject] {
        subjects.filter { !$0.isArchived }
    }

    public func subject(named name: String) -> Subject? {
        sortableSubjects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? sortableSubjects.first { $0.aliases.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    public func subject(_ id: Subject.ID) -> Subject? {
        subjects.first { $0.id == id }
    }
}

/// A kind of document, such as "Past Papers". Its name doubles as the folder name.
public struct DocumentType: Hashable, Codable, Sendable {
    public var name: String
    /// Words that identify this kind of document, such as "worksheet" or "exam paper".
    public var aliases: [String]
    /// Kinds of file that are always this type, as content types such as
    /// "public.audio". They win over words in the file.
    public var fileKinds: [String]

    public init(name: String, aliases: [String] = [], fileKinds: [String] = []) {
        self.name = name
        self.aliases = aliases
        self.fileKinds = fileKinds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        fileKinds = try container.decodeIfPresent([String].self, forKey: .fileKinds) ?? []
    }
}

/// An exam or qualification, such as the HSC or GCSE.
public struct ExamBoard: Hashable, Codable, Sendable {
    public var name: String
    public var aliases: [String]

    public init(name: String, aliases: [String] = []) {
        self.name = name
        self.aliases = aliases
    }
}

/// A rule the student set, such as "file names containing MATH1131 go to Mathematics".
public struct SortingRule: Identifiable, Hashable, Codable, Sendable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case fileName
        /// The web address a file was downloaded from.
        case sourceURL
        /// The name of the folder the file came from.
        case sourceFolder
    }

    public var id: UUID
    public var field: Field
    /// Matched case-insensitively anywhere in the field.
    public var contains: String
    public var subjectID: Subject.ID
    public var documentType: String?

    public init(id: UUID = UUID(), field: Field, contains: String, subjectID: Subject.ID, documentType: String? = nil) {
        self.id = id
        self.field = field
        self.contains = contains
        self.subjectID = subjectID
        self.documentType = documentType
    }
}

/// Whether the student is at school or university, which changes the defaults.
public enum StudyLevel: String, Codable, Sendable, CaseIterable {
    case school
    case university
}

/// How sure Folio must be before it files something without asking.
public enum AutoFileLevel: String, Codable, Sendable, CaseIterable {
    /// Only when separate signals agree. Anything else waits in "Needs a look".
    case careful
    /// Also when one strong signal stands alone and nothing disagrees.
    case balanced
    /// Whenever there's a clear front-runner.
    case eager
}
