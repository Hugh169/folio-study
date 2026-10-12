import FolioKit

/// The settings a test sorts with, and the subject each labelled file should
/// end up in.
struct Run {
    let id: String
    let name: String
    let profile: Profile
    /// The profile's subject for a label, or nil when the profile has no such
    /// subject and the file is left out.
    let subjectName: (String) -> String?

    /// Folio's five sample subjects, which the test labels name directly.
    static func starter() -> Run {
        let profile = Profile.starter()
        return Run(id: "sample", name: "Sample subjects", profile: profile) { profile.subject(named: $0)?.name }
    }

    /// A student taking a curriculum pack's courses. Test files are labelled
    /// with subject areas such as "History", so each area in the test set is
    /// stood in for by the course most students take in it (Modern History in
    /// the HSC). Areas the pack doesn't teach are left out.
    static func pack(_ pack: CurriculumPack, areas: Set<String>) -> Run {
        self.pack(pack, topics: topics(named: areas), id: pack.id, name: pack.name)
    }

    /// The same areas shared among students of up to `size` subjects each, as
    /// real students have, starting with the courses most students take.
    static func groups(of pack: CurriculumPack, areas: Set<String>, size: Int) -> [Run] {
        let wanted = topics(named: areas)
        var order: [String] = []
        for course in pack.chipCourses + pack.subjects where wanted.contains(course.topic) && !order.contains(course.topic) {
            order.append(course.topic)
        }
        return stride(from: 0, to: order.count, by: max(size, 1)).enumerated().map { index, start in
            let topics = Set(order[start..<min(start + size, order.count)])
            return self.pack(pack, topics: topics, id: "\(pack.id)-\(index + 1)", name: "\(pack.name) student \(index + 1)")
        }
    }

    private static func topics(named areas: Set<String>) -> Set<String> {
        let topicNamed = Dictionary(PackLibrary.topics.values.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        return Set(areas.compactMap { topicNamed[$0] })
    }

    private static func pack(_ pack: CurriculumPack, topics: Set<String>, id: String, name: String) -> Run {
        // In the pack's own order, as a student would add them.
        let courses = pack.subjects.filter { topics.contains($0.topic) && pack.typicalCourse(inTopic: $0.topic) == $0 }
        let profile = pack.profile(subjects: courses.map { pack.subject(for: $0, colorHex: 0x8E8E93) })
        var courseForArea: [String: String] = [:]
        for course in courses {
            if let area = PackLibrary.topics[course.topic]?.name { courseForArea[area] = course.name }
        }
        return Run(id: id, name: name, profile: profile) { courseForArea[$0] }
    }
}
