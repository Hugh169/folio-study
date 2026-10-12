import FolioKit
import SwiftUI

/// A file linked to an assessment, as its sheet lists it.
struct LinkedFile: Identifiable, Hashable {
    var id: UUID
    var name: String
    var role: FileRole?
    var url: URL?
}

extension AppModel {
    // MARK: Assessments

    /// Adds an assessment, or updates it if it's already there. A new mark
    /// is dated, so the weekly review can say it came back.
    func saveAssessment(_ assessment: Assessment, sourcePath: String? = nil) {
        var assessment = assessment
        let saved = assessments.first { $0.id == assessment.id }
        if assessment.mark == nil {
            assessment.markedAt = nil
        } else if assessment.mark != saved?.mark && assessment.markedAt == saved?.markedAt {
            assessment.markedAt = .now
        }
        if let index = assessments.firstIndex(where: { $0.id == assessment.id }) {
            assessments[index] = assessment
        } else {
            assessments.append(assessment)
        }
        assessments.sort { $0.due < $1.due }
        guard let live else { return }
        if let record = live.store.assessmentRecord(assessment.id) {
            record.update(from: assessment)
        } else {
            live.store.insert(AssessmentRecord(assessment, sourcePath: sourcePath))
        }
        live.store.save()
        live.librarian?.update(assessments: assessments)
        syncReminder(for: assessment)
    }

    func setStatus(_ status: Assessment.Status, of assessment: Assessment) {
        var updated = assessment
        updated.status = status
        saveAssessment(updated)
    }

    func deleteAssessment(_ assessment: Assessment) {
        assessments.removeAll { $0.id == assessment.id }
        guard let live else { return }
        for item in live.store.filedItems(linkedTo: assessment.id) {
            live.store.link(item.id, to: nil, role: nil)
        }
        sessions.removeAll { $0.assessmentID == assessment.id && $0.start > .now }
        live.store.replaceSessions(with: sessions)
        releaseTodos(of: assessment.id)
        if let record = live.store.assessmentRecord(assessment.id) {
            removeReminder(id: record.reminderID)
            live.store.delete(record)
            live.store.save()
        }
        live.librarian?.update(assessments: assessments)
    }

    /// Adds several at once, such as a timetable of exams.
    func addAssessments(_ new: [Assessment]) {
        for assessment in new {
            saveAssessment(assessment)
        }
    }

    func assessment(_ id: Assessment.ID) -> Assessment? {
        assessments.first { $0.id == id }
    }

    /// Not yet handed in or sat, due within `days` days, soonest first.
    func upcomingAssessments(within days: Int, now: Date = .now) -> [Assessment] {
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: days, to: today) ?? today
        return assessments.filter { !$0.isDone && $0.due >= today && $0.due < horizon }
    }

    /// Not handed in or sat, and due before today.
    func overdueAssessments(now: Date = .now) -> [Assessment] {
        assessments.filter { !$0.isDone && $0.due < calendar.startOfDay(for: now) }
    }

    func assessments(of subjectID: Subject.ID) -> [Assessment] {
        assessments.filter { $0.subjectID == subjectID }
    }

    /// "in 3 days", "tomorrow" or "today", for countdowns.
    func countdown(to date: Date, now: Date = .now) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return String(localized: "Overdue")
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        default: return String(localized: "In \(days) days")
        }
    }

    // MARK: Files and assessments

    /// The files linked to an assessment, oldest first.
    func linkedFiles(of assessment: Assessment) -> [LinkedFile] {
        guard let live else { return [] }
        return live.store.filedItems(linkedTo: assessment.id).map { item in
            LinkedFile(id: item.id, name: item.name, role: item.fileRole, url: libraryURL?.appending(path: item.relativePath))
        }
    }

    func unlinkFile(_ file: LinkedFile) {
        live?.store.link(file.id, to: nil, role: nil)
    }

    /// Offers what a filed file says about assessments: a new one it sets, or
    /// a link to one the student already has.
    func offerAssessment(from record: FiledRecord) {
        guard let reading = record.reading, let suggestion = suggestion(for: reading, in: record) else { return }
        let known = assessmentSuggestions.contains { $0.offer == suggestion.offer && $0.subjectID == suggestion.subjectID }
        guard !known else { return }
        withAnimation(Theme.motion()) {
            assessmentSuggestions.append(suggestion)
        }
    }

    private func suggestion(for reading: AssessmentReader.Reading, in record: FiledRecord) -> AssessmentSuggestion? {
        let base = AssessmentSuggestion(
            offer: .link(UUID(), .resource),
            subjectID: record.subjectID,
            fileID: record.id,
            fileName: record.name,
            filePath: record.url.path(percentEncoded: false),
            mark: reading.mark
        )
        let inSubject = assessments.filter { $0.subjectID == record.subjectID }

        if let found = reading.assessment {
            // A task sheet for an assessment the student already has is linked, not added twice.
            if let existing = inSubject.first(where: { $0.title.localizedCaseInsensitiveCompare(found.title) == .orderedSame || (calendar.isDate($0.due, inSameDayAs: found.due) && $0.kind == found.kind) }) {
                var link = base
                link.offer = .link(existing.id, reading.role ?? .taskSheet)
                return link
            }
            var new = base
            new.offer = .new(found)
            return new
        }
        if let mentioned = reading.mentioned, let role = reading.role {
            var link = base
            link.offer = .link(mentioned, Self.role(role, fileName: record.name))
            return link
        }
        switch reading.role {
        case .criteria:
            // Criteria go with the subject's next assessment.
            guard let next = inSubject.filter({ !$0.isDone && $0.due > .now }).min(by: { $0.due < $1.due }) else { return nil }
            var link = base
            link.offer = .link(next.id, .criteria)
            return link
        case .returned:
            // Marked work comes back after it was due.
            guard let last = inSubject.filter({ $0.mark == nil && $0.due <= .now }).max(by: { $0.due < $1.due }) else { return nil }
            var link = base
            link.offer = .link(last.id, .returned)
            return link
        default:
            return nil
        }
    }

    /// A file named like a draft is a draft.
    private static func role(_ role: FileRole, fileName: String) -> FileRole {
        guard role == .resource else { return role }
        return fileName.localizedCaseInsensitiveContains("draft") ? .draft : role
    }

    /// The assessment a suggestion would add, for its card and for editing.
    func draft(from suggestion: AssessmentSuggestion) -> Assessment? {
        guard case .new(let found) = suggestion.offer else { return nil }
        return Assessment(
            title: found.title,
            subjectID: suggestion.subjectID,
            kind: found.kind,
            due: found.due,
            lengthMinutes: found.lengthMinutes,
            weighting: found.weighting,
            totalMarks: found.totalMarks,
            milestones: Assessment.suggestedMilestones(for: found.kind, due: found.due, calendar: calendar),
            source: .file
        )
    }

    /// Adds the assessment or makes the link. `edited` replaces the suggested
    /// assessment when the student changed it first.
    func accept(_ suggestion: AssessmentSuggestion, edited: Assessment? = nil) {
        withAnimation(Theme.motion()) {
            assessmentSuggestions.removeAll { $0.id == suggestion.id }
        }
        switch suggestion.offer {
        case .new:
            guard let assessment = edited ?? draft(from: suggestion) else { return }
            saveAssessment(assessment, sourcePath: suggestion.filePath)
            if let fileID = suggestion.fileID {
                live?.store.link(fileID, to: assessment.id, role: .taskSheet)
            }
        case .link(let id, let role):
            if let fileID = suggestion.fileID {
                live?.store.link(fileID, to: id, role: role)
            }
            if let mark = suggestion.mark, var assessment = assessment(id), assessment.mark == nil {
                assessment.mark = mark
                assessment.status = .marked
                saveAssessment(assessment)
            }
        }
    }

    func dismiss(_ suggestion: AssessmentSuggestion) {
        withAnimation(Theme.motion()) {
            assessmentSuggestions.removeAll { $0.id == suggestion.id }
        }
    }
}

extension Assessment.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .task: "Task"
        case .homework: "Homework"
        case .exam: "Exam"
        case .test: "Test"
        case .presentation: "Presentation"
        case .practical: "Practical"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .task: "doc.text"
        case .homework: "pencil.line"
        case .exam: "pencil.and.list.clipboard"
        case .test: "checklist"
        case .presentation: "person.wave.2"
        case .practical: "flask"
        case .other: "star"
        }
    }
}

extension Assessment.Status {
    var title: LocalizedStringResource {
        switch self {
        case .notStarted: "Not started"
        case .inProgress: "In progress"
        case .submitted: "Submitted"
        case .marked: "Marked"
        }
    }
}

extension FileRole {
    var title: LocalizedStringResource {
        switch self {
        case .taskSheet: "Task sheet"
        case .criteria: "Marking criteria"
        case .resource: "Resource"
        case .draft: "Draft"
        case .submitted: "Submitted work"
        case .returned: "Marked work"
        }
    }
}

extension Assessment {
    /// "25%", "18/25 · B+" or "Band 6", for rows and cards.
    var markText: String? {
        guard let mark else { return nil }
        var parts: [String] = []
        if let score = mark.score {
            let outOf = mark.outOf ?? totalMarks
            parts.append(outOf.map { "\(score.formatted())/\($0.formatted())" } ?? score.formatted())
        }
        if let grade = mark.grade {
            parts.append(grade)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var weightingText: String? {
        weighting.map { "\($0.formatted())%" }
    }
}

extension Assessment.Mark {
    /// "74/100", "74", "A" or "18/25 · B+".
    var text: String? {
        var parts: [String] = []
        if let score {
            parts.append(outOf.map { "\(score.formatted())/\($0.formatted())" } ?? score.formatted())
        }
        if let grade { parts.append(grade) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
