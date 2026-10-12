import SwiftUI
import FolioKit

/// The study timer's small window: what the session is for, the time left,
/// the plan to tick off, the files it needs, and "How did it go?" at the end.
/// It floats above other windows, so the time stays in view while the student
/// works in their files.
struct FocusWindow: View {
    static let id = "focus"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let focus = model.focus {
                if focus.isOver {
                    FocusFinish(focus: focus) { dismissWindow(id: Self.id) }
                } else {
                    FocusRunning(focus: focus)
                }
            } else {
                VStack(spacing: 12) {
                    IconTile(systemName: "timer", foreground: Theme.accent, background: Theme.accent.opacity(0.16), size: 44, cornerRadius: 12, symbolSize: 19)
                    Text("No study session running")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Start one from Today, the Planner or Study.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Close") { dismissWindow(id: Self.id) }
                        .buttonStyle(.folioGhost)
                        .padding(.top, 4)
                }
                .padding(28)
            }
        }
        .frame(width: 320)
        .background(Theme.windowBackground)
    }
}

/// The header both states share: the subject and what the session is for.
private struct FocusHeader: View {
    @Environment(AppModel.self) private var model
    let focus: FocusSession

    var body: some View {
        let subject = model.subject(focus.subjectID)
        HStack(alignment: .top, spacing: 12) {
            IconTile(
                systemName: focus.paper == nil ? "book" : "doc.text",
                foreground: subject?.tintForeground ?? Theme.primaryText,
                background: subject?.tintBackground ?? Color.white.opacity(0.1)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(subject?.name ?? String(localized: "Study"))
                    .font(.system(size: 14, weight: .semibold))
                Text(focus.title ?? (focus.paper == nil ? String(localized: "General study") : String(localized: "Past paper")))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FocusRunning: View {
    @Environment(AppModel.self) private var model
    let focus: FocusSession

    var body: some View {
        let colour = model.subject(focus.subjectID)?.color ?? Theme.accent
        VStack(alignment: .leading, spacing: 20) {
            FocusHeader(focus: focus)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = focus.remaining(at: context.date)
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: 1 - focus.progress(at: context.date))
                        .stroke(colour, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 3) {
                        Text(Self.clock(remaining))
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(focus.isPaused ? String(localized: "Paused") : String(localized: "of \(focus.minutes) minutes"))
                            .font(.system(size: 12))
                            .foregroundStyle(focus.isPaused ? Theme.warning : Theme.secondaryText)
                    }
                }
                .frame(width: 176, height: 176)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "\(Int((remaining / 60).rounded(.up))) minutes left"))
            }

            HStack(spacing: 8) {
                if focus.isPaused {
                    Button("Resume") { model.resumeFocus() }
                        .buttonStyle(FilledButtonStyle(kind: .primary, fullWidth: true))
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button("Pause") { model.pauseFocus() }
                        .buttonStyle(FilledButtonStyle(kind: .ghost, fullWidth: true))
                        .keyboardShortcut(.space, modifiers: [])
                }
                Button("+5 min") { model.extendFocus(by: 5) }
                    .buttonStyle(FilledButtonStyle(kind: .ghost, fullWidth: true))
                    .help("Add five minutes")
                Button("End") { model.endFocus() }
                    .buttonStyle(FilledButtonStyle(kind: .ghost, fullWidth: true))
                    .help("Stop and say how it went")
            }

            if let id = focus.sessionID, let session = model.session(id) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Your plan", leadingInset: 0)
                    if session.plan.isEmpty {
                        Text("What will you do? Add it here, or pick from Folio's ideas.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Ideas only until there's a plan, so the window stays small.
                    PlanChecklist(sessionID: id, showsSuggestions: session.plan.isEmpty)
                }
            }

            if !focus.files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(focus.paper == nil ? "Your files" : "The paper", leadingInset: 0)
                    ForEach(focus.files, id: \.self) { url in
                        FileLine(url: url)
                    }
                    if focus.paper != nil {
                        Text("The marking guidelines are here when you finish.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        .padding(20)
    }

    /// "24:13", or "1:02:10" for an hour or more.
    static func clock(_ seconds: TimeInterval) -> String {
        let duration = Duration.seconds(Int(seconds.rounded(.up)))
        return seconds >= 3600 ? duration.formatted(.time(pattern: .hourMinuteSecond)) : duration.formatted(.time(pattern: .minuteSecond))
    }
}

/// A file with a button to open it.
private struct FileLine: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(Theme.secondaryText)
            Text(url.lastPathComponent)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button("Open") { model.open(url) }
                .buttonStyle(.folioLink)
        }
    }
}

/// "How did it go?": what was done, how long for, a note, and a past paper's mark.
private struct FocusFinish: View {
    @Environment(AppModel.self) private var model
    let focus: FocusSession
    let close: () -> Void

    @State private var outcome: StudySession.Outcome = .done
    @State private var minutes: Int
    @State private var note = ""
    @State private var score: Double?
    @State private var outOf: Double?

    init(focus: FocusSession, close: @escaping () -> Void) {
        self.focus = focus
        self.close = close
        _minutes = State(initialValue: max(1, Int((focus.studied(at: .now) / 60).rounded())))
    }

    /// Where the steps not ticked off go: the next session for the same
    /// work, or the subject's to-do list.
    private func carryText(for session: StudySession) -> String {
        let subject = model.subject(session.subjectID)?.name ?? ""
        if let next = model.nextSessionForCarrying(from: session) {
            return String(localized: "Anything not ticked off moves to your next \(subject) session, \(next.start.formatted(.dateTime.weekday(.wide).hour().minute())).")
        }
        return String(localized: "Anything not ticked off goes on the \(subject) to-do list.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FocusHeader(focus: focus)

            VStack(alignment: .leading, spacing: 4) {
                Text(focus.remaining(at: .now) <= 0 ? "Time's up" : "Session ended")
                    .font(.system(size: 17, weight: .semibold))
                Text("How did it go?")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }

            Picker("How did it go?", selection: $outcome) {
                Text("Done").tag(StudySession.Outcome.done)
                Text("Partly").tag(StudySession.Outcome.partly)
                Text("Didn't start").tag(StudySession.Outcome.skipped)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let id = focus.sessionID, let session = model.session(id), !session.plan.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    PlanChecklist(sessionID: id, allowsAdding: false, showsSuggestions: false)
                    if outcome != .done, !session.unfinishedSteps.isEmpty {
                        Text(carryText(for: session))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if outcome != .skipped {
                Stepper(value: $minutes, in: 1...600, step: 5) {
                    Text("Studied for \(minutes) minutes")
                        .font(.system(size: 13))
                }
            }

            if let paper = focus.paper, outcome != .skipped {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Your mark", leadingInset: 0)
                    HStack(spacing: 8) {
                        TextField("Mark", value: $score, format: .number)
                            .frame(width: 70)
                        Text("out of")
                            .foregroundStyle(Theme.secondaryText)
                        TextField("Total", value: $outOf, format: .number)
                            .frame(width: 70)
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    if paper.guidelines.isEmpty {
                        Text("Folio hasn't found marking guidelines for this paper. Drop them on Folio and they'll appear here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(paper.guidelines, id: \.self) { guide in
                            Button {
                                model.open(guide.url)
                            } label: {
                                Label("Open \(guide.name)", systemImage: "checkmark.seal")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.folioLink)
                        }
                    }
                }
            }

            TextField(outcome == .skipped ? "What got in the way? (optional)" : "Where did you get up to? (optional)", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            HStack(spacing: 8) {
                Button("+5 min") { model.extendFocus(by: 5) }
                    .buttonStyle(.folioGhost)
                    .help("Keep going for five more minutes")
                Spacer()
                Button("Save") {
                    let mark: Assessment.Mark? = score == nil ? nil : Assessment.Mark(score: score, outOf: outOf)
                    model.finishFocus(outcome: outcome, minutes: minutes, note: note, mark: mark)
                    close()
                }
                .buttonStyle(.folioPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            // A plan ticked off in full was done; one left part-way, partly.
            if let id = focus.sessionID, let plan = model.session(id)?.plan, !plan.isEmpty {
                outcome = plan.allSatisfy(\.isDone) ? .done : .partly
            }
        }
    }
}
