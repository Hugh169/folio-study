import Foundation
import OSLog

/// The curriculum packs and shared subject areas that come with Folio, and
/// reading and writing `.foliopack` files.
public enum PackLibrary {
    private static let log = Logger(subsystem: "Folio", category: "Packs")

    /// Every subject area, by ID.
    public static let topics: [String: Topic] = {
        guard let url = Bundle.module.url(forResource: "Topics", withExtension: "json") else {
            log.error("Topics.json is missing")
            return [:]
        }
        do {
            let list = try JSONDecoder().decode([Topic].self, from: Data(contentsOf: url))
            return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            log.error("Couldn't read Topics.json: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }()

    /// Every pack that comes with Folio, in no particular order.
    public static let packs: [CurriculumPack] = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Packs") ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            do {
                return try decode(Data(contentsOf: url))
            } catch {
                log.error("Couldn't read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }()

    public static func pack(_ id: String) -> CurriculumPack? {
        packs.first { $0.id == id }
    }

    /// The general pack for students whose system isn't listed.
    public static let otherID = "other"
    public static let universityID = "university"

    /// Packs grouped as setup lists them: the groups for `region` (such as
    /// "AU") first, then the rest by name, then University, then Other.
    public static func groups(for region: String? = Locale.current.region?.identifier) -> [(name: String, packs: [CurriculumPack])] {
        let schools = packs.filter { $0.id != otherID && $0.id != universityID }
        let names = Set(schools.map(\.region)).sorted { a, b in
            let aLocal = schools.contains { $0.region == a && region.map($0.regionCodes.contains) == true }
            let bLocal = schools.contains { $0.region == b && region.map($0.regionCodes.contains) == true }
            return aLocal != bLocal ? aLocal : a < b
        }
        var groups = names.map { name in
            (name: name, packs: schools.filter { $0.region == name }.sorted { $0.name < $1.name })
        }
        let rest = [pack(universityID), pack(otherID)].compactMap { $0 }
        if !rest.isEmpty {
            groups.append((name: "", packs: rest))
        }
        return groups
    }

    // MARK: Sharing

    public static let fileExtension = "foliopack"

    public static func decode(_ data: Data) throws -> CurriculumPack {
        try JSONDecoder().decode(CurriculumPack.self, from: data)
    }

    public static func encode(_ pack: CurriculumPack) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(pack)
    }

    /// A pack of a student's own subjects to share: their names, words, codes
    /// and kinds of document, but never their rules, files or name.
    public static func pack(from profile: Profile, name: String) -> CurriculumPack {
        let base = profile.packID.flatMap(pack)
        var usedIDs = Set<String>()
        let courses = profile.sortableSubjects.map { subject in
            var id = slug(subject.name)
            while usedIDs.contains(id) { id += "-2" }
            usedIDs.insert(id)
            return PackSubject(
                id: id,
                name: subject.name,
                topic: subject.topic ?? "",
                aliases: subject.aliases,
                codes: subject.codes,
                keywords: subject.keywords,
                summary: subject.summary,
                languageOfStudy: subject.languageOfStudy
            )
        }
        return CurriculumPack(
            id: "shared-" + slug(name),
            name: name,
            region: base?.region ?? "",
            regionCodes: base?.regionCodes ?? [],
            language: profile.language ?? base?.language ?? "en",
            level: profile.level,
            examBoards: profile.examBoards,
            documentTypes: profile.documentTypes.filter { $0.fileKinds.isEmpty },
            defaultDocumentType: profile.defaultDocumentType,
            folderTemplate: profile.folderTemplate,
            termStyle: base?.termStyle ?? (profile.level == .university ? .regional : .calendarYear),
            schoolHours: profile.studyPreferences.schoolHours,
            subjects: courses,
            suggested: courses.map(\.id)
        )
    }

    static func slug(_ text: String) -> String {
        let folded = TermMatcher.normalize(text)
        let parts = folded.split { !$0.isLetter && !$0.isNumber }
        return parts.isEmpty ? "subject" : parts.joined(separator: "-")
    }

    // MARK: Checking

    /// Everything wrong with a pack, for the tests and for imported files.
    public static func problems(in pack: CurriculumPack, topics: [String: Topic] = topics, minimumWords: Int = 15) -> [String] {
        var problems: [String] = []
        func duplicates(_ values: [String]) -> [String] {
            Dictionary(grouping: values.map { $0.lowercased() }, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        }
        if pack.subjects.isEmpty, pack.level == .school { problems.append("has no subjects") }
        for id in duplicates(pack.subjects.map(\.id)) { problems.append("two subjects have the ID \(id)") }
        for name in duplicates(pack.subjects.map(\.name)) { problems.append("two subjects are called \(name)") }
        for code in duplicates(pack.subjects.flatMap { $0.codes.map(PackSubject.plainCode) }) { problems.append("two subjects have the code \(code)") }
        for name in duplicates(pack.documentTypes.map(\.name)) { problems.append("two kinds of document are called \(name)") }
        for id in pack.suggested + pack.popular where pack.course(id) == nil { problems.append("lists \(id), which isn't a subject") }
        if let fallback = pack.defaultDocumentType, !pack.documentTypes.contains(where: { $0.name == fallback }) {
            problems.append("its default kind of document, \(fallback), isn't one of its kinds")
        }
        for course in pack.subjects {
            let topic = topics[course.topic]
            if topic == nil && !course.topic.isEmpty { problems.append("\(course.name) uses the topic \(course.topic), which doesn't exist") }
            let words = Set(((topic?.keywords ?? []) + course.keywords).map { $0.lowercased() })
            if words.count < minimumWords { problems.append("\(course.name) has only \(words.count) topic words") }
            if (course.summary ?? topic?.summary ?? "").isEmpty { problems.append("\(course.name) has no description") }
        }
        return problems
    }
}
