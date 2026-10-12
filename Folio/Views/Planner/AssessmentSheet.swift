import SwiftUI
import FolioKit

/// Adds an assessment, or edits one: what it is, when, how much it counts,
/// the steps on the way, its files, and the mark once it's back.
struct AssessmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    /// Saves the assessment. By default it goes straight into the planner.
    let onSave: ((Assessment) -> Void)?

    @State private var draft: Assessment
    @State private var weighting = ""
    @State private var estimate = ""
    @State private var score = ""
    @State private var outOf = ""
    @State private var files: [LinkedFile] = []

    /// - Parameters:
    ///   - assessment: The assessment to edit, or a suggested one to add. `nil` starts a new task.
    ///   - isNew: Whether saving adds it rather than updating it.
    init(assessment: Assessment?, isNew: Bool = false, onSave: ((Assessment) -> Void)? = nil) {
        self.isNew = isNew || assessment == nil
        self.onSave = onSave
        _draft = State(initialValue: assessment ?? Assessment(title: "", subjectID: UUID(), due: .now))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Assessment" : "Edit Assessment")
                .font(.system(size: 17, weight: .semibold))
                .padding([.top, .horizontal], 24)

            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("e.g. Depth Study"))
                    Picker("Subject", selection: $draft.subjectID) {
                        ForEach(model.subjects) { subject in
                            HStack {
                                SubjectDot(color: subject.color)
                                Text(subject.name)
                            }
                            .tag(subject.id)
                        }
                    }
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(Assessment.Kind.allCases, id: \.self) { kind in
                            Label(String(localized: kind.title), systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    DatePicker(draft.isSitting ? "Starts" : "Due", selection: $draft.due, displayedComponents: [.date, .hourAndMinute])
                    if draft.isSitting {
                        Stepper(value: lengthBinding, in: 10...360, step: 10) {
                            Text("Lasts \(lengthBinding.wrappedValue) minutes")
                        }
                        TextField("Room", text: roomBinding, prompt: Text("Optional"))
                    }
                }

                Section {
                    LabeledContent("Weighting") {
                        HStack(spacing: 4) {
                            TextField("Weighting", text: $weighting, prompt: Text("e.g. 25"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text(verbatim: "%")
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    TextField("Hours of work", text: $estimate, prompt: Text("About \(draft.defaultEstimateHours.formatted())"))
                        .help("Folio plans this much study before it's due. Leave it empty to use Folio's estimate.")
                    Picker("Status", selection: $draft.status) {
                        ForEach(Assessment.Status.allCases, id: \.self) { status in
                            Text(status.title).tag(status)
                        }
                    }
                }

                if draft.status == .marked {
                    Section("Result") {
                        LabeledContent("Mark") {
                            HStack(spacing: 8) {
                                TextField("Mark", text: $score, prompt: Text(verbatim: "18"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 56)
                                Text("out of")
                                    .foregroundStyle(Theme.secondaryText)
                                TextField("Out of", text: $outOf, prompt: Text(verbatim: draft.totalMarks?.formatted() ?? "25"))
                                    .labelsHidden()
                                    .frame(width: 56)
                            }
                        }
                        TextField("Grade", text: gradeBinding, prompt: Text("Optional, such as B+ or Band 5"))
                        TextField("Feedback", text: $draft.feedback, prompt: Text("What to keep doing, and what to improve"), axis: .vertical)
                            .lineLimit(2...5)
                    }
                }

                // Homework is done in one go, so it has no steps unless the student adds some.
                if !draft.isSitting && (draft.kind != .homework || !draft.milestones.isEmpty) {
                    Section {
                        ForEach($draft.milestones) { $milestone in
                            HStack {
                                Toggle("Done", isOn: $milestone.isDone)
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .accessibilityLabel(milestone.title)
                                TextField("Step", text: $milestone.title)
                                    .labelsHidden()
                                    .textFieldStyle(.plain)
                                Spacer()
                                DatePicker("", selection: $milestone.date, displayedComponents: .date)
                                    .labelsHidden()
                                Button {
                                    draft.milestones.removeAll { $0.id == milestone.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.secondaryText)
                                .accessibilityLabel("Remove \(milestone.title)")
                            }
                        }
                        HStack {
                            Button("Add Step") {
                                let date = model.calendar.date(byAdding: .day, value: -3, to: draft.due) ?? draft.due
                                draft.milestones.append(Assessment.Milestone(title: String(localized: "Draft"), date: max(date, .now)))
                            }
                            if draft.milestones.isEmpty {
                                Button("Suggest Steps") {
                                    draft.milestones = Assessment.suggestedMilestones(for: draft.kind, due: draft.due, calendar: model.calendar)
                                }
                            }
                        }
                    } header: {
                        Text("Steps")
                    } footer: {
                        Text("Study sessions before a step are named after it.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }

                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files) { file in
                            LinkedFileRow(file: file) {
                                model.unlinkFile(file)
                                files.removeAll { $0.id == file.id }
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $draft.notes, prompt: Text("Anything to remember"), axis: .vertical)
                        .lineLimit(2...6)
                        .labelsHidden()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        withAnimation(Theme.motion()) { model.deleteAssessment(draft) }
                        dismiss()
                    }
                }
                Spacer()
                if model.usesReminders {
                    Text("Also in Reminders")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Assessment" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || model.subject(draft.subjectID) == nil)
            }
            .padding([.horizontal, .bottom], 24)
            .padding(.top, 8)
        }
        .frame(width: 520, height: 640)
        .onAppear(perform: load)
    }

    private var trimmedTitle: String {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lengthBinding: Binding<Int> {
        Binding(get: { draft.lengthMinutes ?? 60 }, set: { draft.lengthMinutes = $0 })
    }

    private var roomBinding: Binding<String> {
        Binding(get: { draft.room ?? "" }, set: { draft.room = $0.isEmpty ? nil : $0 })
    }

    private var gradeBinding: Binding<String> {
        Binding(get: { draft.mark?.grade ?? "" }, set: { grade in
            var mark = draft.mark ?? Assessment.Mark()
            mark.grade = grade.isEmpty ? nil : grade
            draft.mark = mark
        })
    }

    private func load() {
        if model.subject(draft.subjectID) == nil {
            draft.subjectID = model.subjects.first?.id ?? draft.subjectID
        }
        if isNew && draft.title.isEmpty {
            // A new task defaults to 9 am a week from now.
            let nextWeek = model.calendar.date(byAdding: .day, value: 7, to: .now) ?? .now
            draft.due = model.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextWeek) ?? nextWeek
        }
        weighting = draft.weighting?.formatted() ?? ""
        estimate = draft.estimateHours?.formatted() ?? ""
        score = draft.mark?.score?.formatted() ?? ""
        outOf = draft.mark?.outOf?.formatted() ?? ""
        files = isNew ? [] : model.linkedFiles(of: draft)
    }

    private func save() {
        var saved = draft
        saved.title = trimmedTitle
        saved.weighting = Self.number(weighting).map { min(max($0, 0), 100) }
        saved.estimateHours = Self.number(estimate)
        if saved.status == .marked {
            var mark = saved.mark ?? Assessment.Mark()
            mark.score = Self.number(score)
            mark.outOf = Self.number(outOf) ?? saved.totalMarks
            saved.mark = mark.score == nil && mark.grade == nil ? nil : mark
        }
        if !saved.isSitting {
            saved.lengthMinutes = nil
            saved.room = nil
        }
        withAnimation(Theme.motion()) {
            if let onSave {
                onSave(saved)
            } else {
                model.saveAssessment(saved)
            }
        }
        dismiss()
    }

    /// A number typed in the student's own format, such as "2,5" in French.
    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard !trimmed.isEmpty else { return nil }
        return (try? Double(trimmed, format: .number)) ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

/// A file linked to an assessment, with buttons to open it, show it, or unlink it.
struct LinkedFileRow: View {
    @Environment(AppModel.self) private var model
    let file: LinkedFile
    let unlink: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let role = file.role {
                    Text(role.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            if let url = file.url {
                Button("Open") { model.open(url) }
                    .buttonStyle(.folioLink)
                Button {
                    model.showInFinder(url)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            Button {
                unlink()
            } label: {
                Image(systemName: "link.badge.minus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Unlink this file")
            .accessibilityLabel("Unlink")
        }
    }
}
