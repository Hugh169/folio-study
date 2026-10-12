import SwiftUI
import FolioKit

/// A to-do list: one subject's, or every subject's with their colours. Plan
/// My Week puts these into study sessions; ticking one off here ticks it off
/// in any session it's planned for.
struct TodoList: View {
    @Environment(AppModel.self) private var model
    /// One subject's list, or `nil` for every subject's.
    let subjectID: Subject.ID?
    /// Shows this many at most.
    var limit: Int?

    @State private var newTitle = ""
    @State private var newSubjectID: Subject.ID?
    @State private var editing: Todo?
    @State private var showsDone = false

    var body: some View {
        let open = model.openTodos(in: subjectID)
        let shown = limit.map { Array(open.prefix($0)) } ?? open
        let done = model.doneTodos(in: subjectID)
        VStack(alignment: .leading, spacing: 0) {
            if open.isEmpty {
                Text(subjectID == nil
                     ? "Nothing to do yet. Add things like “Copy up Tuesday's notes”, and Plan My Week finds time for them."
                     : "Nothing to do yet. Add jobs for this subject that aren't assessments, and Plan My Week finds time for them.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
            }
            ForEach(shown) { todo in
                TodoRow(todo: todo, showsSubject: subjectID == nil) { editing = todo }
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
            if open.count > shown.count {
                Text("and \(open.count - shown.count) more")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.vertical, 8)
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
            if showsDone {
                ForEach(done) { todo in
                    TodoRow(todo: todo, showsSubject: subjectID == nil) { editing = todo }
                    Rectangle().fill(Theme.separator).frame(height: 1)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: PlanStepRow.boxWidth)
                if subjectID == nil {
                    Picker("Subject", selection: $newSubjectID) {
                        ForEach(model.subjects) { subject in
                            Text(verbatim: subject.name).tag(Optional(subject.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.subjects.isEmpty)
                }
                TextField("Add a to-do", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(add)
                if !done.isEmpty {
                    Button(showsDone ? String(localized: "Hide Done") : String(localized: "Show Done")) {
                        withAnimation(Theme.motion()) { showsDone.toggle() }
                    }
                    .buttonStyle(.folioLink)
                    .font(.system(size: 12))
                }
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        .sheet(item: $editing) { todo in
            TodoSheet(todo: todo)
        }
        .onAppear {
            if newSubjectID == nil { newSubjectID = model.subjects.first?.id }
        }
    }

    private func add() {
        guard let subject = subjectID ?? newSubjectID else { return }
        withAnimation(Theme.motion()) {
            _ = model.addTodo(newTitle, subjectID: subject)
        }
        newTitle = ""
    }
}

/// A to-do with a tick box. Clicking its words opens it to change.
private struct TodoRow: View {
    @Environment(AppModel.self) private var model
    let todo: Todo
    let showsSubject: Bool
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(todo.title, isOn: Binding(
                get: { todo.isDone },
                set: { done in withAnimation(Theme.motion()) { model.setTodo(todo, done: done) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: PlanStepRow.boxWidth)
            .padding(.top, 1)
            .shotTarget("todo-\(todo.id)")
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.title)
                        .font(.system(size: 13))
                        .foregroundStyle(todo.isDone ? Theme.tertiaryText : Theme.primaryText)
                        .strikethrough(todo.isDone, color: Theme.tertiaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change this to-do")
            if showsSubject, let subject = model.subject(todo.subjectID) {
                SubjectDot(color: subject.color)
                    .padding(.top, 5)
                    .help(subject.name)
            }
        }
        .padding(.vertical, 9)
        .contextMenu {
            Button("Edit To-Do…", action: edit)
            Button("Delete To-Do", role: .destructive) {
                withAnimation(Theme.motion()) { model.deleteTodo(todo) }
            }
        }
    }

    /// "Physics · for Prac report · 20 min".
    private var detail: String? {
        var parts: [String] = []
        if showsSubject, let subject = model.subject(todo.subjectID) { parts.append(subject.name) }
        if let id = todo.assessmentID, let assessment = model.assessment(id) {
            parts.append(String(localized: "for \(assessment.title)"))
        }
        if let minutes = todo.minutes { parts.append(StudyFormat.duration(minutes: minutes)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Changes a to-do: its words, subject, the assessment it's part of, and how long it takes.
struct TodoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Todo

    static let lengths = [10, 15, 20, 30, 45, 60, 90, 120]

    init(todo: Todo) {
        _draft = State(initialValue: todo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit To-Do")
                .font(.system(size: 15, weight: .semibold))
            Form {
                TextField("To-do", text: $draft.title, axis: .vertical)
                    .lineLimit(1...3)
                Picker("Subject", selection: $draft.subjectID) {
                    ForEach(model.subjects) { subject in
                        Text(verbatim: subject.name).tag(subject.id)
                    }
                }
                Picker("For", selection: $draft.assessmentID) {
                    Text("Nothing in particular").tag(Assessment.ID?.none)
                    ForEach(model.assessments(of: draft.subjectID).filter { !$0.isDone || $0.id == draft.assessmentID }) { assessment in
                        Text(assessment.title).tag(Optional(assessment.id))
                    }
                }
                Picker("Takes about", selection: $draft.minutes) {
                    Text("Not sure").tag(Int?.none)
                    ForEach(Set(Self.lengths + [draft.minutes].compactMap { $0 }).sorted(), id: \.self) { minutes in
                        Text(StudyFormat.duration(minutes: minutes)).tag(Optional(minutes))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            HStack {
                Button("Delete", role: .destructive) {
                    model.deleteTodo(draft)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = draft
                    saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.saveTodo(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: draft.subjectID) {
            if let id = draft.assessmentID, model.assessment(id)?.subjectID != draft.subjectID {
                draft.assessmentID = nil
            }
        }
    }
}
