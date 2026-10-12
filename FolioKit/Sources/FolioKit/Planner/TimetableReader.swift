import Foundation

/// Finds courses in a university timetable: event titles such as "COMP1511
/// Lecture" or "MATH1131 - Mathematics 1A - Tutorial" become COMP1511 and
/// MATH1131 (Mathematics 1A), offered to the student as subjects.
public enum TimetableReader {
    public struct Course: Identifiable, Hashable, Sendable {
        /// The course code, such as "COMP1511", without a space.
        public var code: String
        /// The course's name when a title includes one, such as "Mathematics 1A".
        public var name: String?
        /// How many classes in the timetable are for it.
        public var classCount: Int

        public var id: String { code }
    }

    /// The courses in these event titles, busiest first.
    public static func courses(in titles: [String]) -> [Course] {
        var counts: [String: Int] = [:]
        var names: [String: [String: Int]] = [:]
        for title in titles {
            guard let code = code(in: title) else { continue }
            counts[code, default: 0] += 1
            if let name = name(in: title) {
                names[code, default: [:]][name, default: 0] += 1
            }
        }
        return counts.map { code, count in
            Course(code: code, name: names[code]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key, classCount: count)
        }
        .sorted { ($1.classCount, $0.code) < ($0.classCount, $1.code) }
    }

    /// The classes in these timetable events, matched to the student's
    /// subjects by course code, name or other name. Events that match no
    /// subject, or more than one, are left out.
    public static func classes(from events: [BusyBlock], subjects: [Subject]) -> [ClassSession] {
        events.compactMap { event -> ClassSession? in
            guard !event.isAllDay else { return nil }
            let matching = subjects.filter { matches(event.title, $0) }
            guard matching.count == 1, let subject = matching.first else { return nil }
            return ClassSession(subjectID: subject.id, title: event.title, start: event.start, end: event.end)
        }
    }

    static func matches(_ title: String, _ subject: Subject) -> Bool {
        let squash = { (text: String) in text.uppercased().filter { !$0.isWhitespace } }
        if let code = code(in: title) {
            let known = (subject.codes + [subject.name, subject.effectiveFolderName]).map(squash)
            if known.contains(code) { return true }
        }
        let text = TermMatcher.normalize(title)
        return ([subject.name] + subject.aliases).contains { name in
            name.count >= 3 && TermMatcher.contains(TermMatcher.normalize(name), in: text)
        }
    }

    /// A course code: 2–5 capital letters, then 3–5 digits and maybe a letter,
    /// such as COMP1511, "MATH 1131" or FIT1045.
    public static func code(in title: String) -> String? {
        guard let match = title.firstMatch(of: codePattern) else { return nil }
        return String(match.output.1) + String(match.output.2)
    }

    private static var codePattern: Regex<(Substring, Substring, Substring)> {
        /\b([A-Z]{2,5}) ?(\d{3,5}[A-Z]?)\b/
    }

    /// What's left of a title once the code, the kind of class and class
    /// numbers like "T13A" are taken out, if it's a real name.
    static func name(in title: String) -> String? {
        var text = title.replacing(codePattern, with: " ")
        text = text.replacing(/(?i)\b(lecture|lec|tutorial|tute|tut|laboratory|lab|workshop|seminar|practical|prac|studio|help session|consultation|online|in-person|week)\b\s*\d*/, with: " ")
        text = text.replacing(/\b[A-Z]\d{2}[A-Z]?\b/, with: " ")
        text = text.replacing(/\(\s*\)|\[\s*\]/, with: " ")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let separators = CharacterSet(charactersIn: " -–—:|/,.()[]")
        text = text.trimmingCharacters(in: separators)
        guard text.count >= 3, text.contains(where: \.isLetter) else { return nil }
        return text
    }
}
