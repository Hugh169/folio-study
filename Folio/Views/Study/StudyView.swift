import SwiftUI
import FolioKit

/// Everything for studying: flashcards to review, a timer to start, the
/// week's study so far, to-dos, each subject's cards, and how recent
/// sessions went.
struct StudyView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewing: ReviewRequest?
    @State private var making: MakeCardsRequest?
    @State private var isAddingCard = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            Screen(title: "Study", subtitle: subtitle(at: now)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack(alignment: .top, spacing: 16) {
                            ReviewCard(now: now, review: { reviewing = ReviewRequest(cards: model.dueCards(at: now)) }, make: { making = MakeCardsRequest() })
                            StudyNowCard()
                            WeekCard(now: now)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("To do")
                            TodoList(subjectID: nil, limit: 8)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionTitle("Flashcards")
                                Spacer()
                                Button("Add a Card…") { isAddingCard = true }
                                    .buttonStyle(.folioLink)
                                Button("Make Cards…") { making = MakeCardsRequest() }
                                    .buttonStyle(.folioLink)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                                ForEach(model.subjects) { subject in
                                    DeckTile(subject: subject, now: now) {
                                        reviewing = ReviewRequest(cards: model.dueCards(at: now, in: subject.id), subjectID: subject.id)
                                    } make: {
                                        making = MakeCardsRequest(subjectID: subject.id)
                                    }
                                }
                            }
                        }

                        RecentStudy()
                    }
                    .padding(28)
                    .frame(maxWidth: 1240, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // Every main screen has a toolbar item, so the window's toolbar keeps
        // its height and the sidebar doesn't jump when switching screens.
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                AddFilesButton()
            }
        }
        .sheet(item: $reviewing) { request in
            ReviewSheet(cards: request.cards, subjectID: request.subjectID)
        }
        .sheet(item: $making) { request in
            MakeCardsSheet(subjectID: request.subjectID, file: request.file)
        }
        .sheet(isPresented: $isAddingCard) {
            CardEditor(card: nil)
        }
        .onAppear(perform: openPendingReview)
        .onChange(of: model.pendingReview) { openPendingReview() }
    }

    /// Opens a review another window asked for, such as the timer's plan.
    private func openPendingReview() {
        guard let subjectID = model.pendingReview else { return }
        model.pendingReview = nil
        reviewing = ReviewRequest(cards: model.dueCards(in: subjectID), subjectID: subjectID)
    }

    /// "12 cards to review · 1 h 40 m studied this week".
    private func subtitle(at now: Date) -> String {
        let due = model.dueCards(at: now).count
        let studied = model.studyMinutes(inWeekOf: now).recorded
        var parts: [String] = []
        if due > 0 { parts.append(String(localized: "\(due) cards to review")) }
        if studied > 0 { parts.append(String(localized: "\(StudyFormat.duration(minutes: studied)) studied this week")) }
        return parts.joined(separator: " · ")
    }
}

/// Cards to review in one sitting.
struct ReviewRequest: Identifiable {
    let id = UUID()
    var cards: [Flashcard]
    var subjectID: Subject.ID?
}

/// What to make cards from, if the student already chose.
struct MakeCardsRequest: Identifiable {
    let id = UUID()
    var subjectID: Subject.ID?
    var file: URL?
}

/// Times as the student reads them.
enum StudyFormat {
    /// "45m", "1h 40m", "3h", in the student's language.
    static func duration(minutes: Int) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 60 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(minutes * 60).formatted(.units(allowed: units, width: .narrow))
    }
}

/// The cards waiting today, with Start Review.
private struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    let review: () -> Void
    let make: () -> Void

    var body: some View {
        let due = model.dueCards(at: now)
        let subjects = Set(due.map(\.subjectID)).count
        VStack(alignment: .leading, spacing: 14) {
            IconTile(systemName: "rectangle.on.rectangle.angled", foreground: Color.white, background: Theme.accent.opacity(0.55), size: 40, cornerRadius: 11, symbolSize: 17)
            if model.flashcards.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No flashcards yet")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Folio can write them from your own notes, on this Mac.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    step(1, "Pick a file of notes, slides or a recorded lesson.")
                    step(2, "The on-device AI writes questions, each answered in your file.")
                    step(3, "Keep the ones you want, and review a few each day.")
                }
                Spacer(minLength: 0)
                Button("Make Cards…", action: make)
                    .buttonStyle(.folioPrimary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(due.isEmpty ? String(localized: "All reviewed") : String(localized: "\(due.count) cards to review"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(due.isEmpty
                         ? nextReviewText
                         : String(localized: "From \(subjects) subjects. Cards you know come back less often."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let first = due.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Up first")
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.tertiaryText)
                        Text(first.question)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(Color.white.opacity(0.06)))
                }
                Spacer(minLength: 0)
                Button("Start Review", action: review)
                    .buttonStyle(.folioPrimary)
                    .disabled(due.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.24), Theme.purple.opacity(0.12), Theme.cardBackground], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.accent.opacity(0.22), lineWidth: 1))
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(number.formatted())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accentText)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent.opacity(0.2)))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Next cards tomorrow", or when they're due.
    private var nextReviewText: String {
        guard let next = model.flashcards.map(\.due).filter({ $0 > now }).min() else { return "" }
        if model.calendar.isDateInTomorrow(next) { return String(localized: "The next cards come back tomorrow.") }
        return String(localized: "The next cards come back \(next.formatted(.dateTime.weekday(.wide).day().month(.wide))).")
    }
}

/// Start the timer for any subject, for 25, 45 or 60 minutes.
private struct StudyNowCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var subjectID: Subject.ID?
    @State private var minutes = 45

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            IconTile(systemName: "timer", foreground: Theme.success, background: Theme.success.opacity(0.16), size: 40, cornerRadius: 11, symbolSize: 17)
            VStack(alignment: .leading, spacing: 4) {
                Text("Study now")
                    .font(.system(size: 17, weight: .semibold))
                Text("A timer that records what you actually did.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Subject", selection: $subjectID) {
                ForEach(model.subjects) { subject in
                    Text(verbatim: subject.name).tag(Optional(subject.id))
                }
            }
            .labelsHidden()
            .disabled(model.subjects.isEmpty)
            Picker("Length", selection: $minutes) {
                Text("25 min").tag(25)
                Text("45 min").tag(45)
                Text("60 min").tag(60)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer(minLength: 0)
            Button(model.focus == nil ? "Start Timer" : "Show Timer") {
                if model.focus == nil, let subjectID = subjectID ?? model.subjects.first?.id {
                    model.startFocus(subjectID: subjectID, minutes: minutes)
                }
                openWindow(id: FocusWindow.id)
            }
            .buttonStyle(.folioGhost)
            .disabled(model.subjects.isEmpty)
        }
        .padding(20)
        .frame(width: 280, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
        .onAppear { subjectID = subjectID ?? model.subjects.first?.id }
    }
}

/// Time recorded this week against time planned.
private struct WeekCard: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let minutes = model.studyMinutes(inWeekOf: now)
        VStack(alignment: .leading, spacing: 12) {
            IconTile(systemName: "chart.bar.fill", foreground: Theme.warning, background: Theme.warning.opacity(0.16), size: 40, cornerRadius: 11, symbolSize: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(StudyFormat.duration(minutes: minutes.recorded))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Studied this week")
                    .font(.system(size: 13, weight: .medium))
                Text(minutes.planned > 0 ? String(localized: "Of \(StudyFormat.duration(minutes: minutes.planned)) planned. Finish sessions with the timer, or mark them done in the Planner.") : String(localized: "Plan your week, then finish sessions with the timer."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if minutes.planned > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Theme.warning)
                            .frame(width: proxy.size.width * min(1, CGFloat(minutes.recorded) / CGFloat(minutes.planned)))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
        }
        .padding(20)
        .frame(width: 280, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
    }
}

/// One subject's cards: how many, how many are due, and how many are learnt.
private struct DeckTile: View {
    @Environment(AppModel.self) private var model
    let subject: Subject
    let now: Date
    let review: () -> Void
    let make: () -> Void

    var body: some View {
        let cards = model.cards(of: subject.id)
        let due = model.dueCards(at: now, in: subject.id).count
        let learnt = cards.filter(\.isLearnt).count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Capsule().fill(subject.color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: subject.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                    Text(cards.isEmpty ? String(localized: "No cards yet") : [String(localized: "\(cards.count) cards"), String(localized: "\(learnt) learnt")].joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                if due > 0 {
                    Text("\(due) due")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(subject.tintForeground)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(subject.color.opacity(0.22)))
                }
            }
            if !cards.isEmpty {
                // Each card in its box: learnt ones on the right.
                HStack(spacing: 2) {
                    ForEach(1...Flashcard.boxCount, id: \.self) { box in
                        let count = cards.filter { $0.box == box }.count
                        Rectangle()
                            .fill(subject.color.opacity(0.25 + 0.15 * Double(box)))
                            .frame(maxWidth: .infinity)
                            .frame(height: 5)
                            .opacity(count == 0 ? 0.25 : 1)
                    }
                }
                .clipShape(Capsule())
                .accessibilityHidden(true)
            }
            HStack(spacing: 4) {
                if due > 0 {
                    Button("Review", action: review)
                        .buttonStyle(.folioLink)
                }
                Button("Make Cards…", action: make)
                    .buttonStyle(.folioLink)
            }
            .padding(.leading, -4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(subject.color.opacity(0.1)))
        .accessibilityElement(children: .contain)
    }
}

/// Sessions the student recorded, with how they went.
private struct RecentStudy: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sessions = model.recordedSessions()
        let attempts = model.practiceAttempts.sorted { $0.date > $1.date }.prefix(4)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Recent study")
            if sessions.isEmpty && attempts.isEmpty {
                Text("Sessions you finish with the timer appear here, with how they went.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        SessionLine(session: session)
                        if session.id != sessions.last?.id || !attempts.isEmpty {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                    ForEach(Array(attempts)) { attempt in
                        AttemptLine(attempt: attempt)
                        if attempt.id != attempts.last?.id {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
        }
    }
}

private struct SessionLine: View {
    @Environment(AppModel.self) private var model
    let session: StudySession

    var body: some View {
        let subject = model.subject(session.subjectID)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(for: session.outcome))
                .font(.system(size: 15))
                .foregroundStyle(session.outcome == .skipped ? Theme.tertiaryText : subject?.color ?? Theme.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.map { "\(subject?.name ?? "") · \($0)" } ?? subject?.name ?? "")
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if let note = session.note {
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.outcomeText(session))
                    .font(.system(size: 12.5, weight: .medium))
                Text(session.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    static func symbol(for outcome: StudySession.Outcome?) -> String {
        switch outcome {
        case .done, nil: "checkmark.circle.fill"
        case .partly: "circle.lefthalf.filled"
        case .skipped: "minus.circle"
        }
    }

    /// "Done · 45 min", "Partly · 20 min" or "Didn't start".
    static func outcomeText(_ session: StudySession) -> String {
        let minutes = StudyFormat.duration(minutes: session.doneMinutes ?? 0)
        switch session.outcome {
        case .done, nil: return String(localized: "Done · \(minutes)")
        case .partly: return String(localized: "Partly · \(minutes)")
        case .skipped: return String(localized: "Didn't start")
        }
    }
}

private struct AttemptLine: View {
    @Environment(AppModel.self) private var model
    let attempt: PracticeAttempt

    var body: some View {
        let subject = model.subject(attempt.subjectID)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(subject?.color ?? Theme.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(subject?.name ?? "") · \((attempt.paperName as NSString).deletingPathExtension)")
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if !attempt.note.isEmpty {
                    Text(attempt.note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(attempt.mark?.text ?? StudyFormat.duration(minutes: attempt.minutes))
                    .font(.system(size: 12.5, weight: .medium))
                Text(attempt.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
