import SwiftUI
import FolioKit

/// A study session's plan: what the student means to do, ticked off as they
/// go, with a field to add more and Folio's suggestions.
struct PlanChecklist: View {
    @Environment(AppModel.self) private var model
    let sessionID: StudySession.ID
    /// Shows this many items at most, such as on Today.
    var limit: Int?
    var allowsAdding = true
    var showsSuggestions = true
    var now: Date = .now

    @State private var newStep = ""

    var body: some View {
        if let session = model.session(sessionID) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(limit.map { Array(session.plan.prefix($0)) } ?? session.plan) { step in
                    PlanStepRow(step: step, session: session)
                }
                if let limit, session.plan.count > limit {
                    Text("and \(session.plan.count - limit) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, PlanStepRow.textInset)
                }
                if allowsAdding {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: PlanStepRow.boxWidth)
                        TextField("Add to your plan", text: $newStep)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .onSubmit(add)
                    }
                }
                if showsSuggestions {
                    PlanSuggestionList(session: session, now: now)
                        .padding(.top, session.plan.isEmpty ? 0 : 4)
                }
            }
        }
    }

    private func add() {
        model.addStep(titled: newStep, to: sessionID)
        newStep = ""
    }
}

/// One item of a plan: a tick box, what it is, and a way to get on with it,
/// such as reviewing the cards or opening the paper.
struct PlanStepRow: View {
    static let boxWidth: CGFloat = 18
    static let textInset: CGFloat = 26

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let step: PlanStep
    let session: StudySession

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(step.title, isOn: Binding(
                get: { step.isDone },
                set: { done in withAnimation(Theme.motion()) { model.setStep(step, in: session.id, done: done) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: Self.boxWidth)
            .padding(.top, 1)
            .shotTarget("step-\(step.id)")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(step.title)
                    .font(.system(size: 13))
                    .foregroundStyle(step.isDone ? Theme.tertiaryText : Theme.primaryText)
                    .strikethrough(step.isDone, color: Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                action
            }
        }
        .contextMenu {
            Button("Remove from Plan") {
                withAnimation(Theme.motion()) { model.removeStep(step, from: session.id) }
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch step.kind {
        case .cards where !step.isDone:
            Button("Review") {
                // Reviews happen in the main window, where there's room for the cards.
                model.pendingReview = session.subjectID
                model.destination = .study
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.folioLink)
            .help("Review this subject's cards in the main window")
        case .paper:
            if let url = model.paper(for: step, in: session.subjectID)?.file.url {
                Button("Open") { model.open(url) }
                    .buttonStyle(.folioLink)
            }
        default:
            EmptyView()
        }
    }
}

/// Folio's ideas for a plan, each added with a click.
struct PlanSuggestionList: View {
    @Environment(AppModel.self) private var model
    let session: StudySession
    var now: Date = .now

    var body: some View {
        let suggestions = model.suggestions(for: session, now: now)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Suggestions")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    if suggestions.count > 1 {
                        Button("Add All") {
                            withAnimation(Theme.motion()) { model.addSteps(suggestions, to: session.id) }
                        }
                        .buttonStyle(.folioLink)
                        .font(.system(size: 12))
                    }
                }
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, step in
                    Button {
                        withAnimation(Theme.motion()) { model.addSteps([step], to: session.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Theme.accentText)
                                .frame(width: PlanStepRow.boxWidth)
                            Text(step.title)
                                .foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shotTarget("suggestion-\(index)")
                    .help("Add to the plan")
                    .accessibilityLabel(String(localized: "Add \(step.title) to the plan"))
                }
            }
        }
    }
}
