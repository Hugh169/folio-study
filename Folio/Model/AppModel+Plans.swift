import FolioKit
import SwiftUI

/// What the student means to do in each study session, sessions they make
/// themselves, and each subject's to-do list.
extension AppModel {
    // MARK: Sessions

    func session(_ id: StudySession.ID) -> StudySession? {
        sessions.first { $0.id == id }
    }

    func saveSessions() {
        live?.store.replaceSessions(with: sessions)
    }

    /// Adds a session the student made, or saves their changes to one. Either
    /// way Plan My Week leaves it where it is.
    func saveSession(_ session: StudySession) {
        var session = session
        session.isOwn = true
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        saveSessions()
    }

    /// Removes a session. What was left of its plan moves on to the subject's next session.
    func removeSession(_ session: StudySession, now: Date = .now) {
        sessions.removeAll { $0.id == session.id }
        if !session.isRecorded {
            carrySteps(of: session, now: now)
        }
        saveSessions()
    }

    // MARK: Plans

    /// Ticks a step of a session's plan, or unticks it. A to-do ticks off with it.
    func setStep(_ step: PlanStep, in sessionID: StudySession.ID, done: Bool, now: Date = .now) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let position = sessions[index].plan.firstIndex(where: { $0.id == step.id })
        else { return }
        sessions[index].plan[position].isDone = done
        sessions[index].isOwn = true
        saveSessions()
        if step.kind == .todo, let todo = todo(for: step), todo.isDone != done {
            setTodo(todo, done: done, now: now)
        }
    }

    func addSteps(_ steps: [PlanStep], to sessionID: StudySession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].plan.add(steps)
        sessions[index].isOwn = true
        saveSessions()
    }

    /// Adds a step the student typed.
    func addStep(titled title: String, to sessionID: StudySession.ID) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        addSteps([PlanStep(title: title)], to: sessionID)
    }

    func removeStep(_ step: PlanStep, from sessionID: StudySession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].plan.removeAll { $0.id == step.id }
        sessions[index].isOwn = true
        saveSessions()
    }

    /// Ideas for a session's plan, from what Folio knows about the work.
    func suggestions(for session: StudySession, now: Date = .now) -> [PlanStep] {
        PlanSuggestions.suggestions(
            for: session,
            assessment: session.assessmentID.flatMap(assessment),
            previous: previousSession(before: session, now: now),
            todos: todos,
            dueCards: dueCards(at: max(now, session.start), in: session.subjectID).count,
            paper: unpractisedPaper(in: session.subjectID),
            now: now
        )
    }

    /// The last recorded session for the same work in the past four weeks:
    /// the same assessment, or general study in the subject.
    func previousSession(before session: StudySession, now: Date = .now) -> StudySession? {
        let since = calendar.date(byAdding: .day, value: -28, to: now) ?? now
        return sessions
            .filter {
                $0.id != session.id && $0.subjectID == session.subjectID && $0.assessmentID == session.assessmentID
                    && $0.isRecorded && $0.start < session.start && $0.end >= since
            }
            .max { $0.end < $1.end }
    }

    /// The newest past paper in the subject the student hasn't practised.
    func unpractisedPaper(in subjectID: Subject.ID) -> PlanSuggestions.Paper? {
        let practised = Set(practiceAttempts.filter { $0.subjectID == subjectID }.map(\.paperName))
        guard let paper = papers(of: subjectID).first(where: { !$0.isGuidelinesOnly && !practised.contains($0.file.name) }) else { return nil }
        return PlanSuggestions.Paper(title: paper.title, fileName: paper.file.name)
    }

    /// The past paper a step is about.
    func paper(for step: PlanStep, in subjectID: Subject.ID) -> PastPapers.Paper? {
        guard step.kind == .paper, let name = step.reference else { return nil }
        return papers(of: subjectID).first { $0.file.name == name }
    }

    /// Sends the steps a session didn't get to on to the subject's next
    /// session. With nowhere to go, the student's own steps join the
    /// subject's to-do list. The caller saves the sessions.
    func carrySteps(of session: StudySession, now: Date = .now) {
        let left = sessions.carrySteps(of: session, now: now)
        for step in left where step.kind == .own {
            addTodo(step.title, subjectID: session.subjectID, assessmentID: session.assessmentID, now: now)
        }
    }

    /// Done ticks off the whole plan, to-dos included. Otherwise the steps
    /// left move on to the next session.
    func finishPlan(at index: Int, outcome: StudySession.Outcome, now: Date) {
        if outcome == .done {
            let todoSteps = sessions[index].plan.filter { $0.kind == .todo && !$0.isDone }
            for position in sessions[index].plan.indices {
                sessions[index].plan[position].isDone = true
            }
            for step in todoSteps {
                if let todo = todo(for: step), !todo.isDone { setTodo(todo, done: true, now: now) }
            }
        } else {
            carrySteps(of: sessions[index], now: now)
        }
    }

    /// Where unticked steps go when the session ends, for "How did it go?":
    /// the next session for the same work, if there is one.
    func nextSessionForCarrying(from session: StudySession, now: Date = .now) -> StudySession? {
        sessions.indexForCarrying(from: session, now: now).map { sessions[$0] }
    }

    // MARK: To-dos

    /// Open to-dos, oldest first, in one subject or all of them.
    func openTodos(in subjectID: Subject.ID? = nil) -> [Todo] {
        todos.filter { !$0.isDone && (subjectID == nil || $0.subjectID == subjectID) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// To-dos ticked off lately, newest first.
    func doneTodos(in subjectID: Subject.ID? = nil, limit: Int = 5) -> [Todo] {
        Array(todos.filter { $0.isDone && (subjectID == nil || $0.subjectID == subjectID) }.sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }.prefix(limit))
    }

    func todo(for step: PlanStep) -> Todo? {
        guard step.kind == .todo, let id = step.reference.flatMap(UUID.init(uuidString:)) else { return nil }
        return todos.first { $0.id == id }
    }

    @discardableResult
    func addTodo(_ title: String, subjectID: Subject.ID, assessmentID: Assessment.ID? = nil, minutes: Int? = nil, now: Date = .now) -> Todo? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let todo = Todo(subjectID: subjectID, title: title, assessmentID: assessmentID, minutes: minutes, createdAt: now)
        saveTodo(todo)
        return todo
    }

    /// Adds or updates a to-do. Steps made from it in sessions still to come
    /// take its new words and whether it's done.
    func saveTodo(_ todo: Todo) {
        if let index = todos.firstIndex(where: { $0.id == todo.id }) {
            todos[index] = todo
        } else {
            todos.append(todo)
        }
        live?.store.save(todo)

        let reference = todo.id.uuidString
        var changed = false
        for index in sessions.indices where !sessions[index].isRecorded {
            for position in sessions[index].plan.indices where sessions[index].plan[position].kind == .todo && sessions[index].plan[position].reference == reference {
                guard sessions[index].plan[position].title != todo.title || sessions[index].plan[position].isDone != todo.isDone else { continue }
                sessions[index].plan[position].title = todo.title
                sessions[index].plan[position].isDone = todo.isDone
                changed = true
            }
        }
        if changed { saveSessions() }
    }

    func setTodo(_ todo: Todo, done: Bool, now: Date = .now) {
        var changed = todo
        changed.isDone = done
        changed.doneAt = done ? now : nil
        saveTodo(changed)
    }

    /// Deletes a to-do, and takes it out of the plans of sessions still to come.
    func deleteTodo(_ todo: Todo) {
        todos.removeAll { $0.id == todo.id }
        live?.store.deleteTodo(todo.id)
        let reference = todo.id.uuidString
        var changed = false
        for index in sessions.indices where !sessions[index].isRecorded {
            let count = sessions[index].plan.count
            sessions[index].plan.removeAll { $0.kind == .todo && $0.reference == reference }
            changed = changed || sessions[index].plan.count != count
        }
        if changed { saveSessions() }
    }

    /// To-dos for an assessment that's gone stay on the subject's list.
    func releaseTodos(of assessmentID: Assessment.ID) {
        for todo in todos where todo.assessmentID == assessmentID {
            var released = todo
            released.assessmentID = nil
            saveTodo(released)
        }
    }

    func loadTodos() {
        guard let live else { return }
        todos = live.store.todoRecords().map(\.todo)
    }
}
