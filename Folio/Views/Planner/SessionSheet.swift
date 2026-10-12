import SwiftUI
import FolioKit

/// Adds a study session, or changes one: the subject, what it's for, when,
/// and the plan of what to do in it. Either way it becomes the student's
/// own, so Plan My Week leaves it where it is.
struct SessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State private var draft: StudySession
    @State private var title: String
    @State private var newStep = ""

    static let lengths = [30, 45, 60, 75, 90, 120, 150, 180]

    /// - Parameters:
    ///   - session: The session to change. `nil` starts a new one at `start`.
    init(session: StudySession?, start: Date = .now, subjectID: Subject.ID? = nil, minutes: Int = 60) {
        isNew = session == nil
        let draft = session ?? StudySession(subjectID: subjectID ?? UUID(), start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))
        _draft = State(initialValue: draft)
        _title = State(initialValue: draft.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Study Session" : "Edit Study Session")
                .font(.system(size: 17, weight: .semibold))
                .padding([.top, .horizontal], 24)

            Form {
                Section {
                    Picker("Subject", selection: $draft.subjectID) {
                        ForEach(model.subjects) { subject in
                            HStack {
                                SubjectDot(color: subject.color)
                                Text(subject.name)
                            }
                            .tag(subject.id)
                        }
                    }
                    Picker("For", selection: $draft.assessmentID) {
                        Text("General study").tag(Assessment.ID?.none)
                        ForEach(assessments) { assessment in
                            Text(assessment.title).tag(Optional(assessment.id))
                        }
                    }
                    TextField("Title", text: $title, prompt: Text(titlePrompt))
                    DatePicker("Day", selection: startBinding, displayedComponents: .date)
                    DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
                    Picker("Length", selection: lengthBinding) {
                        ForEach(lengthChoices, id: \.self) { minutes in
                            Text(StudyFormat.duration(minutes: minutes)).tag(minutes)
                        }
                    }
                }

                Section {
                    ForEach($draft.plan) { $step in
                        HStack(spacing: 8) {
                            Toggle(step.title, isOn: $step.isDone)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            if step.kind == .own {
                                TextField("Item", text: $step.title)
                                    .labelsHidden()
                                    .textFieldStyle(.plain)
                            } else {
                                Text(step.title)
                            }
                            Spacer()
                            Button {
                                draft.plan.removeAll { $0.id == step.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityLabel("Remove \(step.title)")
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                        TextField("Add to your plan", text: $newStep, prompt: Text("e.g. Questions 21 to 25 of the 2019 paper"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .onSubmit(addTypedStep)
                    }
                    let suggestions = model.suggestions(for: draft)
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Suggestions")
                                    .font(.system(size: 11, weight: .semibold))
                                    .textCase(.uppercase)
                                    .foregroundStyle(Theme.tertiaryText)
                                Spacer()
                                if suggestions.count > 1 {
                                    Button("Add All") { draft.plan.add(suggestions) }
                                        .buttonStyle(.folioLink)
                                }
                            }
                            ForEach(suggestions) { step in
                                Button {
                                    draft.plan.add([step])
                                } label: {
                                    Label(step.title, systemImage: "plus.circle")
                                        .multilineTextAlignment(.leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Plan")
                } footer: {
                    Text("What you'll do when you sit down. Anything you don't tick off moves to your next session.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        withAnimation(Theme.motion()) { model.removeSession(draft) }
                        dismiss()
                    }
                }
                Spacer()
                if let clash {
                    Label(clash, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Session" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.subject(draft.subjectID) == nil)
            }
            .padding([.horizontal, .bottom], 24)
            .padding(.top, 8)
        }
        .frame(width: 500, height: 640)
        .onAppear {
            if model.subject(draft.subjectID) == nil {
                draft.subjectID = model.subjects.first?.id ?? draft.subjectID
            }
        }
        .onChange(of: draft.subjectID) {
            // Work for another subject can't stay chosen.
            if let id = draft.assessmentID, !assessments.contains(where: { $0.id == id }) {
                draft.assessmentID = nil
            }
        }
    }

    /// The subject's assessments still to come, and the one already chosen.
    private var assessments: [Assessment] {
        model.assessments(of: draft.subjectID).filter { !$0.isDone || $0.id == draft.assessmentID }
    }

    private var chosenAssessment: Assessment? {
        draft.assessmentID.flatMap(model.assessment)
    }

    private var titlePrompt: String {
        chosenAssessment?.title ?? String(localized: "Optional")
    }

    /// Moves the session, keeping its length.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { start in
            let length = draft.end.timeIntervalSince(draft.start)
            draft.start = start
            draft.end = start.addingTimeInterval(length)
        })
    }

    private var lengthBinding: Binding<Int> {
        Binding(get: { draft.minutes }, set: { draft.end = draft.start.addingTimeInterval(TimeInterval($0 * 60)) })
    }

    /// The usual lengths, and this session's own if it's different.
    private var lengthChoices: [Int] {
        Set(Self.lengths + [draft.minutes]).sorted()
    }

    /// Something already happening then: another session, an exam or an event.
    private var clash: String? {
        let time = { (date: Date) in date.formatted(.dateTime.hour().minute()) }
        if let other = model.sessions.first(where: { $0.id != draft.id && $0.start < draft.end && draft.start < $0.end }) {
            let name = model.subject(other.subjectID)?.name ?? ""
            return String(localized: "Clashes with \(name) at \(time(other.start))")
        }
        if let exam = model.assessments.first(where: { $0.sitting.map { $0.start < draft.end && draft.start < $0.end } == true }) {
            return String(localized: "Clashes with \(exam.title) at \(time(exam.due))")
        }
        if let event = model.calendarEvents.first(where: { !$0.isAllDay && $0.start < draft.end && draft.start < $0.end }) {
            return String(localized: "Clashes with \(event.title) at \(time(event.start))")
        }
        return nil
    }

    private func addTypedStep() {
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft.plan.add([PlanStep(title: text)])
        newStep = ""
    }

    private func save() {
        addTypedStep()
        var saved = draft
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.title = typed.isEmpty ? chosenAssessment?.title : typed
        saved.plan.removeAll { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        withAnimation(Theme.motion()) { model.saveSession(saved) }
        // To-dos ticked here are ticked off their list too.
        for step in saved.plan where step.kind == .todo {
            if let todo = model.todo(for: step), todo.isDone != step.isDone {
                model.setTodo(todo, done: step.isDone)
            }
        }
        dismiss()
    }
}

/// A new session the planner is asked for, starting at a time.
struct NewSessionRequest: Identifiable {
    let id = UUID()
    var start: Date
    var subjectID: Subject.ID?
}
