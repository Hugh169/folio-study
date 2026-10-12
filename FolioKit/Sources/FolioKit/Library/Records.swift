import Foundation

/// A file Folio filed, as the app shows it under "Recently sorted".
public struct FiledRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var subjectID: Subject.ID
    /// The folder below the subject's folder, such as "Past Papers".
    public var folder: String?
    public var url: URL
    public var filedAt: Date
    /// What Folio worked out, such as "Past Papers · HSC 2023 · 12 pages".
    public var detail: String
    public var reasons: [String]
    public var chosenByStudent: Bool
    /// What it says about an assessment: one it sets, its marking criteria,
    /// a mark, or an open assessment it names. Offered to the student to confirm.
    public var reading: AssessmentReader.Reading?
}

/// A file waiting under "Needs a look".
public struct ReviewRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var question: String
    /// Best guesses, offered as one-click choices. Empty means offer every subject.
    public var suggestions: [Subject.ID]
    public var reasons: [String]
    public var detail: String
    public var addedAt: Date
    /// The folder Folio wasn't allowed to move it out of, if that's why it's waiting.
    public var blockedFolder: URL?

    init(_ entry: ReviewEntry) {
        id = entry.id
        name = entry.name
        url = entry.url
        question = entry.question
        suggestions = entry.suggestions
        reasons = entry.reasons
        detail = entry.detail
        addedAt = entry.addedAt
        blockedFolder = entry.blockedFolderPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}
