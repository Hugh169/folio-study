import SwiftUI
import FolioKit

// Subject, StudySession, Assessment and SchoolHours live in FolioKit.

/// A folder inside a subject, such as "Past Papers", and how many files it holds.
struct SubjectFolder: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var fileCount: Int
    /// Where it is on disk, when Folio is sorting real files.
    var url: URL? = nil
}

/// A file that has been filed, shown under "Recently sorted".
struct SortedFile: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subjectID: Subject.ID
    var folder: String?
    var sortedAt: Date
    var url: URL? = nil
}

/// A file in the batch currently being sorted.
struct SortingItem: Identifiable {
    enum Status: Equatable {
        case reading
        case filed(subjectID: Subject.ID, folder: String?)
        /// Waiting under "Needs a look".
        case needsLook
        /// Doesn't look like schoolwork, so it stayed where it was.
        case leftAlone
        /// Already filed, or a copy of a file being sorted.
        case duplicate
        case failed
    }

    var id = UUID()
    var name: String
    /// What Folio has worked out so far, such as "Worksheet · 3 pages".
    var detail: String
    var status: Status

    var isDone: Bool { status != .reading }
}

/// A file Folio wasn't sure about, waiting under "Needs a look".
struct ReviewItem: Identifiable {
    var id = UUID()
    var name: String
    var question: String
    /// Best guesses, offered as one-click choices. Empty means offer every subject.
    var suggestions: [Subject.ID]
    var folder: String?
    /// Why Folio wasn't sure, such as "Found “titration”".
    var reasons: [String] = []
    var url: URL? = nil
    /// The folder macOS wouldn't let Folio move it out of, if that's why it's waiting.
    var blockedFolder: URL? = nil
}

/// Something Folio found in a file it filed, waiting for a yes or no: a new
/// assessment, or a link from the file to one the student already has.
struct AssessmentSuggestion: Identifiable, Hashable {
    enum Offer: Hashable {
        /// An assessment the file sets, or a date it gives for one.
        case new(AssessmentReader.Found)
        /// The file belongs to an assessment the student already has.
        case link(Assessment.ID, FileRole)
    }

    var id = UUID()
    var offer: Offer
    var subjectID: Subject.ID
    /// The filed file, so it can be linked.
    var fileID: UUID?
    var fileName: String
    var filePath: String?
    /// The mark on returned work, recorded when the link is accepted.
    var mark: Assessment.Mark?
}

/// How the planner shows things.
enum PlannerMode: String, CaseIterable, Identifiable {
    case day, week, month, assessments

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .assessments: "Assessments"
        }
    }
}

enum Destination: Hashable {
    case today
    case inbox
    case library
    case planner
    case study
    case progress
    case subject(Subject.ID)
}

/// "1 file" or "3 files", in the student's language.
func fileCountText(_ count: Int) -> String {
    String(localized: "\(count) files")
}
