import Foundation

/// Where filed files go inside the library, such as "{subject}/{type}".
///
/// Each "/"-separated part is one folder. Placeholders are filled in from the
/// file's subject and details. A folder whose placeholder isn't known for a
/// file is skipped, so with "{subject}/{year}" a file with no year goes
/// straight into its subject's folder.
public struct FolderTemplate: Hashable, Sendable, CustomStringConvertible {
    public enum Placeholder: String, CaseIterable, Sendable {
        case subject, type, year, exam
        /// The subject's term, such as "2027 Semester 1".
        case term
    }

    public enum Problem: Hashable, Sendable {
        /// There's no "{subject}" folder.
        case noSubjectFolder
        /// "{subject}" is used more than once, or shares a folder with other text.
        case subjectNotOnItsOwn
        case unknownPlaceholder(String)
        /// A folder is "." or "..".
        case invalidFolder(String)
    }

    public var pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    /// Subject, then document type: "History/Past Papers".
    public static let standard = FolderTemplate("{subject}/{type}")

    public var description: String { pattern }

    /// The template's folders in order, such as ["{subject}", "{type}"].
    public var parts: [String] {
        pattern.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Which part is the subject's own folder.
    public var subjectIndex: Int? {
        parts.firstIndex { $0.lowercased() == "{subject}" }
    }

    /// What's wrong with the template, or `nil` if it can be used.
    public var problem: Problem? {
        for part in parts {
            if part == "." || part == ".." { return .invalidFolder(part) }
            if let unknown = Self.placeholderNames(in: part).first(where: { Placeholder(rawValue: $0.lowercased()) == nil }) {
                return .unknownPlaceholder(unknown)
            }
        }
        let subjectParts = parts.filter { Self.placeholders(in: $0).contains(.subject) }
        if subjectParts.isEmpty { return .noSubjectFolder }
        if subjectParts.count > 1 || subjectIndex == nil { return .subjectNotOnItsOwn }
        return nil
    }

    /// The folders to file into, such as ["History", "Past Papers"].
    public func folders(for subject: Subject, facets: Facets) -> [String] {
        parts.compactMap { part -> String? in
            var isMissing = false
            let filled = part.replacing(Self.placeholderPattern) { match -> String in
                let value: String? = switch Placeholder(rawValue: match.output.1.lowercased()) {
                case .subject: subject.effectiveFolderName
                case .type: facets.documentType
                case .year: facets.year.map(String.init)
                case .exam: facets.exam
                case .term: subject.term
                case nil: nil
                }
                guard let value, !value.isEmpty else {
                    isMissing = true
                    return ""
                }
                return value
            }
            guard !isMissing else { return nil }
            let name = Self.cleanFolderName(filled)
            return name.isEmpty ? nil : name
        }
    }

    /// A name that's safe for a folder on a Mac and in cloud drives that sync
    /// to other systems: no slashes, colons or other reserved characters, no
    /// leading dot that would hide it, and no stray spaces.
    public static func cleanFolderName(_ name: String) -> String {
        let reserved: Set<Character> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"]
        var cleaned = String(name.map { reserved.contains($0) ? "-" : $0 })
        cleaned = String(cleaned.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
        return String(cleaned.prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Placeholders

    private static var placeholderPattern: Regex<(Substring, Substring)> { /\{([A-Za-z]+)\}/ }

    static func placeholderNames(in part: String) -> [String] {
        part.matches(of: placeholderPattern).map { String($0.output.1) }
    }

    static func placeholders(in part: String) -> [Placeholder] {
        placeholderNames(in: part).compactMap { Placeholder(rawValue: $0.lowercased()) }
    }
}
