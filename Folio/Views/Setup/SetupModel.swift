import AppKit
import FolioKit
import SwiftUI

/// What the student has chosen so far during setup.
@Observable
final class SetupModel {
    enum Step: Int, CaseIterable, Identifiable {
        case school, subjects, folders, week, done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .school: String(localized: "Where you study")
            case .subjects: String(localized: "Subjects")
            case .folders: String(localized: "Folders")
            case .week: String(localized: "Your week")
            case .done: String(localized: "All set")
            }
        }
    }

    /// When the student likes to study, which becomes the planner's study times.
    enum StudyTime: String, CaseIterable, Identifiable {
        case mornings, afterSchool, evenings, weekends

        var id: String { rawValue }

        func title(atUniversity: Bool) -> String {
            switch self {
            case .mornings: String(localized: "Mornings")
            case .afterSchool: atUniversity ? String(localized: "Afternoons") : String(localized: "After school")
            case .evenings: String(localized: "Evenings")
            case .weekends: String(localized: "Weekends")
            }
        }
    }

    struct SubjectDraft: Identifiable {
        var subject: Subject
        var isIncluded: Bool
        /// The course in the curriculum pack it came from.
        var courseID: String?
        /// The folder already in the chosen folder, if there is one.
        var existingFolder: String?
        var fileCount = 0
        var showsDetails = false

        var id: UUID { subject.id }
    }

    /// Folder layouts offered in Settings › Folders.
    struct Layout: Identifiable {
        let template: String
        let title: LocalizedStringResource
        var id: String { template }
    }

    static let layouts = [
        Layout(template: "{subject}/{type}", title: "Subject, then kind of document"),
        Layout(template: "{subject}", title: "Subject only"),
        Layout(template: "{subject}/{year}", title: "Subject, then year"),
        Layout(template: "{term}/{subject}/{type}", title: "Term, then subject, then kind"),
    ]

    // MARK: Choices

    /// The welcome screen shows before the steps.
    var showsWelcome = true
    var studentName = ""
    var step = Step.school
    /// The furthest step reached, so the sidebar can go back and forward to it.
    var reached = Step.school

    private(set) var packID: String?
    var drafts: [SubjectDraft] = []
    /// At university: the term the courses are taken in.
    var termName = TermStyle.regional.nextName()

    var watchesDownloads = true
    /// Desktop, Documents or other folders the student allowed Folio to watch.
    var watchedFolders: [URL] = []
    /// Where sorted files go. `nil` means a new Folio folder in Documents, made
    /// when the student continues.
    var library: URL?

    var schoolDays: Set<Int> = [2, 3, 4, 5, 6]
    var schoolStart = 8 * 60 + 45
    var schoolEnd = 15 * 60 + 15
    var studyTimes: Set<StudyTime> = [.afterSchool, .evenings, .weekends]
    var sessionMinutes = 60
    static let sessionLengths = [30, 45, 60, 90]
    /// The school timetable, if the student entered one.
    var timetable: SchoolTimetable?

    var pack: CurriculumPack? { packID.flatMap(PackLibrary.pack) }
    var isUniversity: Bool { pack?.level == .university }
    var includedSubjects: [Subject] { drafts.filter(\.isIncluded).map(\.subject) }

    /// Every subject has a name, and no two share one.
    var subjectsAreValid: Bool {
        let names = includedSubjects.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        return !names.isEmpty && !names.contains("") && Set(names).count == names.count
    }

    func go(to step: Step) {
        self.step = step
        if step.rawValue > reached.rawValue { reached = step }
    }

    // MARK: Where you study

    /// Starts again with a curriculum pack's subjects and school day.
    func choose(_ pack: CurriculumPack) {
        guard pack.id != packID else { return }
        packID = pack.id
        var taken = Set<UInt32>()
        drafts = pack.chipCourses.map { course in
            let isIncluded = pack.suggested.contains(course.id)
            let colour = isIncluded ? Self.colour(notIn: taken) : 0
            if isIncluded { taken.insert(colour) }
            return SubjectDraft(subject: pack.subject(for: course, colorHex: colour), isIncluded: isIncluded, courseID: course.id)
        }
        if let hours = pack.schoolHours {
            schoolDays = hours.weekdays
            schoolStart = hours.start
            schoolEnd = hours.end
        }
        termName = pack.termStyle.nextName()
        // University days are open, so every time of day is on to start with.
        studyTimes = pack.level == .university ? Set(StudyTime.allCases) : [.afterSchool, .evenings, .weekends]
        if let library {
            matchFolders(in: library)
        }
    }

    // MARK: Subjects

    func toggle(_ id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].isIncluded.toggle()
        if drafts[index].isIncluded {
            let others = drafts.filter { $0.isIncluded && $0.id != id }.map(\.subject.colorHex)
            if drafts[index].subject.colorHex == 0 || others.contains(drafts[index].subject.colorHex) {
                drafts[index].subject.colorHex = Self.colour(notIn: Set(others))
            }
        }
    }

    func isChosen(_ course: PackSubject) -> Bool {
        drafts.contains { $0.courseID == course.id && $0.isIncluded }
    }

    /// Ticks a course from the full list, adding it if it isn't a chip yet.
    func toggle(_ course: PackSubject) {
        if let draft = drafts.first(where: { $0.courseID == course.id }) {
            toggle(draft.id)
        } else if let pack {
            let colour = Self.colour(notIn: Set(includedSubjects.map(\.colorHex)))
            drafts.append(SubjectDraft(subject: pack.subject(for: course, colorHex: colour), isIncluded: true, courseID: course.id))
        }
    }

    /// A subject the student typed. A course in their pack, or a common
    /// subject such as "Bio", brings its words with it.
    func addOwn(named text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let pack, let course = pack.course(named: name) {
            if !isChosen(course) { toggle(course) }
            return
        }
        let colour = Self.colour(notIn: Set(includedSubjects.map(\.colorHex)))
        var subject = Subject(name: name, colorHex: colour)
        if let general = PackLibrary.pack(PackLibrary.otherID), let course = general.course(named: name) {
            subject = general.subject(for: course, colorHex: colour)
            if subject.name.caseInsensitiveCompare(name) != .orderedSame {
                subject.aliases.insert(subject.name, at: 0)
                subject.name = name
            }
        }
        drafts.append(SubjectDraft(subject: subject, isIncluded: true))
    }

    /// At university: an empty course to type a code and name into.
    func addCourse() {
        let subject = Subject(name: "", colorHex: Self.colour(notIn: Set(includedSubjects.map(\.colorHex))))
        drafts.append(SubjectDraft(subject: subject, isIncluded: true, showsDetails: true))
    }

    /// Courses found in the student's timetable, added as ticked subjects.
    func addCourses(_ courses: [TimetableReader.Course]) {
        for course in courses {
            guard let index = drafts.firstIndex(where: { $0.subject.codes.contains(course.code) || $0.subject.name.caseInsensitiveCompare(course.code) == .orderedSame }) else {
                let subject = AppModel.subject(for: course, colorHex: Self.colour(notIn: Set(includedSubjects.map(\.colorHex))), term: nil)
                drafts.append(SubjectDraft(subject: subject, isIncluded: true))
                continue
            }
            // A course already listed: add what the timetable knows about it.
            drafts[index].isIncluded = true
            if drafts[index].subject.codes.isEmpty {
                drafts[index].subject.codes = [course.code]
            }
            if let name = course.name, drafts[index].subject.summary.isEmpty {
                drafts[index].subject.summary = name
                if !drafts[index].subject.aliases.contains(name) {
                    drafts[index].subject.aliases.append(name)
                }
            }
        }
    }

    /// The first colour from the palette that isn't taken.
    static func colour(notIn taken: Set<UInt32>) -> UInt32 {
        NewSubjectSheet.palette.first { !taken.contains($0.hex) }?.hex
            ?? NewSubjectSheet.palette[taken.count % NewSubjectSheet.palette.count].hex
    }

    // MARK: Folders

    /// Uses a folder the student chose, and its subject folders for their subjects.
    func useLibrary(_ folder: URL) {
        library = folder
        matchFolders(in: folder)
    }

    /// Chosen subjects use folders that are already there under another name,
    /// and a folder named after a course in the pack adds that course.
    private func matchFolders(in folder: URL) {
        for index in drafts.indices {
            drafts[index].existingFolder = nil
            drafts[index].fileCount = 0
        }
        for child in Self.subfolders(of: folder) where child.lastPathComponent != Organizer.inboxFolderName {
            let name = child.lastPathComponent
            let matches = { (draft: SubjectDraft) in
                ([draft.subject.name] + draft.subject.aliases + draft.subject.codes).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                    || (draft.courseID != nil && self.pack?.course(named: name)?.id == draft.courseID)
            }
            var index = drafts.firstIndex { matches($0) && $0.existingFolder == nil }
            if index == nil, let course = pack?.course(named: name), !drafts.contains(where: { $0.courseID == course.id }) {
                toggle(course)
                index = drafts.indices.last
            }
            guard let index else { continue }
            if !drafts[index].isIncluded { toggle(drafts[index].id) }
            drafts[index].existingFolder = name
            drafts[index].fileCount = Self.fileCount(in: child)
            if drafts[index].subject.effectiveFolderName != name {
                drafts[index].subject.folderName = name
            }
        }
    }

    /// The folders the student turned on, as they'll be shown.
    var libraryDescription: String {
        guard let library else { return "\(HomeFolderPanel.Kind.documents.displayName) / Folio" }
        return library.pathComponents.suffix(2).joined(separator: " / ")
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func fileCount(in folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory != true || values?.isPackage == true { count += 1 }
            if count >= 10_000 { break }
        }
        return count
    }

    // MARK: Your week

    /// The planner's settings from the student's week.
    func studyPreferences(from base: StudyPreferences) -> StudyPreferences {
        typealias Window = StudyPreferences.Window
        var preferences = base
        preferences.sessionMinutes = sessionMinutes
        preferences.longSessionMinutes = max(90, sessionMinutes + 30)
        preferences.schoolHours = isUniversity || schoolDays.isEmpty ? nil : SchoolHours(weekdays: schoolDays, start: schoolStart, end: schoolEnd)
        var weekday: [Window] = []
        if studyTimes.contains(.mornings) {
            weekday.append(isUniversity ? Window(start: 9 * 60, end: 12 * 60 + 30) : Window(start: 7 * 60, end: max(7 * 60 + 30, min(8 * 60 + 15, schoolStart - 30))))
        }
        if studyTimes.contains(.afterSchool) {
            weekday.append(isUniversity ? Window(start: 13 * 60 + 30, end: 18 * 60) : Window(start: min(schoolEnd + 45, 17 * 60), end: 18 * 60 + 30))
        }
        if studyTimes.contains(.evenings) {
            weekday.append(Window(start: 19 * 60, end: 21 * 60 + 30))
        }
        preferences.weekdayWindows = weekday
        preferences.weekendWindows = studyTimes.contains(.weekends) ? StudyPreferences().weekendWindows : []
        return preferences
    }

    /// "After school, Evenings and Weekends", in the student's language.
    var studyTimesDescription: String {
        let names = StudyTime.allCases.filter(studyTimes.contains).map { $0.title(atUniversity: isUniversity) }
        return names.isEmpty ? String(localized: "No study times") : names.formatted(.list(type: .and))
    }

    // MARK: Finishing

    /// The student's settings from everything chosen in setup.
    func makeProfile() -> Profile {
        let term = termName.trimmingCharacters(in: .whitespaces)
        let subjects = includedSubjects.map { subject in
            var subject = subject
            subject.name = subject.name.trimmingCharacters(in: .whitespaces)
            if isUniversity, !term.isEmpty { subject.term = term }
            return subject
        }
        var profile: Profile
        if let pack = pack ?? PackLibrary.pack(PackLibrary.otherID) {
            profile = pack.profile(subjects: subjects)
        } else {
            profile = Profile.starter()
            profile.subjects = subjects
        }
        profile.studyPreferences = studyPreferences(from: profile.studyPreferences)
        let name = studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.studentName = name.isEmpty ? nil : name
        profile.timetable = timetable?.tidied(keeping: Set(subjects.map(\.id)))
        return profile
    }

    /// A timetable to start the editor with: the one entered already, or six
    /// periods within school hours, with this school week as Week A.
    func timetableToEdit(calendar: Calendar) -> SchoolTimetable {
        timetable ?? SchoolTimetable.suggested(
            within: SchoolHours(weekdays: schoolDays, start: schoolStart, end: schoolEnd),
            weekAStart: SchoolTimetable.monday(of: AppModel.schoolWeek(around: .now, calendar: calendar), calendar: calendar)
        )
    }
}
