import Foundation

/// A school system's subjects, exams and kinds of document, such as the NSW HSC
/// or the IB Diploma. Setup builds a student's profile from one, and students
/// can share their own as `.foliopack` files.
public struct CurriculumPack: Codable, Sendable, Identifiable, Hashable {
    /// Such as "au-nsw-hsc".
    public var id: String
    /// Short, such as "NSW HSC".
    public var name: String
    /// Such as "Higher School Certificate".
    public var fullName: String?
    /// The group it's listed under in setup, such as "Australia".
    public var region: String
    /// ISO region codes the pack is for, such as ["AU"], so the Mac's region is listed first.
    public var regionCodes: [String]
    /// The language it's taught in, such as "en".
    public var language: String
    public var level: StudyLevel
    /// Bumped whenever the course list changes.
    public var version: Int
    /// When the course list was last checked against the official one, such as "2026-10".
    public var lastChecked: String?
    public var examBoards: [ExamBoard]
    /// Folder names for kinds of document. Recordings and Videos are added to every pack.
    public var documentTypes: [DocumentType]
    public var defaultDocumentType: String?
    public var folderTemplate: String
    public var termStyle: TermStyle
    public var schoolHours: SchoolHours?
    /// Every course in the system, grouped by `PackSubject.group`.
    public var subjects: [PackSubject]
    /// Courses ticked to start with, by ID.
    public var suggested: [String]
    /// More courses offered as chips in setup, unticked, by ID.
    public var popular: [String]

    public init(
        id: String,
        name: String,
        fullName: String? = nil,
        region: String,
        regionCodes: [String] = [],
        language: String = "en",
        level: StudyLevel = .school,
        version: Int = 1,
        lastChecked: String? = nil,
        examBoards: [ExamBoard] = [],
        documentTypes: [DocumentType] = [],
        defaultDocumentType: String? = nil,
        folderTemplate: String = "{subject}/{type}",
        termStyle: TermStyle = .calendarYear,
        schoolHours: SchoolHours? = nil,
        subjects: [PackSubject] = [],
        suggested: [String] = [],
        popular: [String] = []
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.region = region
        self.regionCodes = regionCodes
        self.language = language
        self.level = level
        self.version = version
        self.lastChecked = lastChecked
        self.examBoards = examBoards
        self.documentTypes = documentTypes
        self.defaultDocumentType = defaultDocumentType
        self.folderTemplate = folderTemplate
        self.termStyle = termStyle
        self.schoolHours = schoolHours
        self.subjects = subjects
        self.suggested = suggested
        self.popular = popular
    }

    // Missing fields fall back to defaults, so hand-made and older packs still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        regionCodes = try container.decodeIfPresent([String].self, forKey: .regionCodes) ?? []
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en"
        level = try container.decodeIfPresent(StudyLevel.self, forKey: .level) ?? .school
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        lastChecked = try container.decodeIfPresent(String.self, forKey: .lastChecked)
        examBoards = try container.decodeIfPresent([ExamBoard].self, forKey: .examBoards) ?? []
        documentTypes = try container.decodeIfPresent([DocumentType].self, forKey: .documentTypes) ?? []
        defaultDocumentType = try container.decodeIfPresent(String.self, forKey: .defaultDocumentType)
        folderTemplate = try container.decodeIfPresent(String.self, forKey: .folderTemplate) ?? "{subject}/{type}"
        termStyle = try container.decodeIfPresent(TermStyle.self, forKey: .termStyle) ?? .calendarYear
        schoolHours = try container.decodeIfPresent(SchoolHours.self, forKey: .schoolHours)
        subjects = try container.decodeIfPresent([PackSubject].self, forKey: .subjects) ?? []
        suggested = try container.decodeIfPresent([String].self, forKey: .suggested) ?? []
        popular = try container.decodeIfPresent([String].self, forKey: .popular) ?? []
    }

    public func course(_ id: String) -> PackSubject? {
        subjects.first { $0.id == id }
    }

    /// Courses ticked to start with.
    public var suggestedCourses: [PackSubject] {
        suggested.compactMap(course)
    }

    /// The chips setup starts with: the suggested courses, then other popular ones.
    public var chipCourses: [PackSubject] {
        (suggested + popular.filter { !suggested.contains($0) }).compactMap(course)
    }

    /// The course a folder or subject name refers to: its name, an alias, a
    /// code, or a name of its topic, ignoring case and accents. A topic's name
    /// gives the course most students take, so "Maths" is Mathematics Advanced.
    public func course(named name: String, topics: [String: Topic] = PackLibrary.topics) -> PackSubject? {
        let wanted = TermMatcher.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !wanted.isEmpty else { return nil }
        let matches = { (candidates: [String]) in candidates.contains { TermMatcher.normalize($0) == wanted } }
        return subjects.first { matches([$0.name]) }
            ?? subjects.first { matches($0.aliases + $0.folderNames + $0.codes.map(PackSubject.plainCode)) }
            ?? subjects.first { matches(topics[$0.topic].map { [$0.name] + $0.names + $0.folderNames } ?? []) }.flatMap { typicalCourse(inTopic: $0.topic) }
    }

    /// The course most students take in a topic: a suggested one, then a
    /// popular one, then the first listed.
    public func typicalCourse(inTopic topic: String) -> PackSubject? {
        let courses = subjects.filter { $0.topic == topic }
        return courses.first { suggested.contains($0.id) }
            ?? courses.first { popular.contains($0.id) }
            ?? courses.first
    }

    /// A subject for one of this pack's courses, with its topic's description
    /// and words copied in, so the student's settings work on their own.
    public func subject(for course: PackSubject, colorHex: UInt32, term: String? = nil, topics: [String: Topic] = PackLibrary.topics) -> Subject {
        let topic = topics[course.topic]
        var aliases = course.aliases
        for name in topic?.names ?? [] where !aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) && name.caseInsensitiveCompare(course.name) != .orderedSame {
            aliases.append(name)
        }
        var keywords = topic?.keywords ?? []
        for word in course.keywords where !keywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            keywords.append(word)
        }
        return Subject(
            name: course.name,
            colorHex: colorHex,
            aliases: aliases,
            codes: course.codes,
            summary: course.summary ?? topic?.summary ?? "",
            keywords: keywords,
            term: term,
            topic: course.topic,
            languageOfStudy: course.languageOfStudy
        )
    }

    /// A profile for this pack with the student's subjects.
    public func profile(subjects: [Subject]) -> Profile {
        var preferences = level == .university ? StudyPreferences.university : StudyPreferences()
        preferences.schoolHours = level == .university ? nil : schoolHours ?? SchoolHours()
        var profile = Profile(
            subjects: subjects,
            documentTypes: documentTypes + Profile.mediaDocumentTypes.filter { media in
                !documentTypes.contains { $0.name.caseInsensitiveCompare(media.name) == .orderedSame }
            },
            examBoards: examBoards,
            defaultDocumentType: defaultDocumentType,
            folderTemplate: folderTemplate,
            level: level,
            studyPreferences: preferences
        )
        profile.packID = id
        profile.language = language
        return profile
    }
}

/// One course in a pack, such as "Mathematics Advanced".
public struct PackSubject: Codable, Sendable, Identifiable, Hashable {
    /// Unique within the pack, such as "maths-advanced".
    public var id: String
    public var name: String
    /// The shared subject area whose description and words it uses, such as "mathematics".
    public var topic: String
    /// Heading it's listed under, such as "Sciences".
    public var group: String?
    /// Other names, searched for in files, such as "PDHPE" or "Maths Advanced".
    public var aliases: [String]
    /// Other names that are also everyday words, such as "Art" or "Methods".
    /// They find a student's folder of that name, but don't count in a file.
    public var folderNames: [String]
    /// Course and exam codes. One ending in "*" also matches longer exam
    /// component codes, so "8461*" finds AQA's "84611H".
    public var codes: [String]
    /// Words on top of the topic's, such as this syllabus's module names.
    public var keywords: [String]
    /// Replaces the topic's description when set.
    public var summary: String?
    /// For language courses: the language studied, such as "fr".
    public var languageOfStudy: String?

    public init(
        id: String,
        name: String,
        topic: String,
        group: String? = nil,
        aliases: [String] = [],
        folderNames: [String] = [],
        codes: [String] = [],
        keywords: [String] = [],
        summary: String? = nil,
        languageOfStudy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.group = group
        self.aliases = aliases
        self.folderNames = folderNames
        self.codes = codes
        self.keywords = keywords
        self.summary = summary
        self.languageOfStudy = languageOfStudy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        topic = try container.decode(String.self, forKey: .topic)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        folderNames = try container.decodeIfPresent([String].self, forKey: .folderNames) ?? []
        codes = try container.decodeIfPresent([String].self, forKey: .codes) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        languageOfStudy = try container.decodeIfPresent(String.self, forKey: .languageOfStudy)
    }

    /// A code without its trailing "*".
    static func plainCode(_ code: String) -> String {
        code.hasSuffix("*") ? String(code.dropLast()) : code
    }
}

/// A subject area shared between packs, such as biology: what it covers and
/// the words that point to it. Every pack's Biology uses the same words.
public struct Topic: Codable, Sendable, Identifiable, Hashable {
    /// Such as "biology".
    public var id: String
    /// Such as "Biology". The test set labels files with these.
    public var name: String
    public var summary: String
    public var keywords: [String]
    /// Other names, searched for in files, such as "Bio". A language's name
    /// in itself counts too, such as "Français".
    public var names: [String]
    /// Names that only find a student's folder: names in other languages, such
    /// as "Biologie" and "生物", and words like "Law" that turn up in other
    /// subjects' files ("Newton's laws").
    public var folderNames: [String]

    public init(id: String, name: String, summary: String, keywords: [String], names: [String] = [], folderNames: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.keywords = keywords
        self.names = names
        self.folderNames = folderNames
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        names = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        folderNames = try container.decodeIfPresent([String].self, forKey: .folderNames) ?? []
    }
}

/// How a school system names its terms, for new-term folders and archives.
public enum TermStyle: String, Codable, Sendable, CaseIterable {
    /// School years that follow the calendar: "2027".
    case calendarYear
    /// School years from September: "2026–27".
    case academicYear
    /// Two semesters a year: "2027 Semester 1".
    case semesters
    /// American semesters: "Spring 2027", "Fall 2027".
    case fallSpring
    /// Whatever's usual where the Mac is: semesters in Australia and New Zealand,
    /// fall and spring in North America, academic years elsewhere.
    case regional

    /// The name of the next term or year to start, as of `date`.
    public func nextName(after date: Date = .now, calendar: Calendar = .current, region: String? = Locale.current.region?.identifier) -> String {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        switch self {
        case .calendarYear:
            return String(month >= 10 ? year + 1 : year)
        case .academicYear:
            let start = month >= 6 ? year : year - 1
            return "\(start)–\(String(format: "%02d", (start + 1) % 100))"
        case .semesters:
            return month >= 7 ? "\(year + 1) Semester 1" : "\(year) Semester 2"
        case .fallSpring:
            return month >= 8 ? "Spring \(year + 1)" : "Fall \(year)"
        case .regional:
            switch region {
            case "AU", "NZ": return TermStyle.semesters.nextName(after: date, calendar: calendar)
            case "US", "CA": return TermStyle.fallSpring.nextName(after: date, calendar: calendar)
            default: return TermStyle.academicYear.nextName(after: date, calendar: calendar)
            }
        }
    }
}
