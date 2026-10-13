import SwiftUI
import FolioKit

/// Goes through the cards that are due: the question, then the answer and the
/// line of the notes it came from, then "Knew It" or "Didn't Know". A missed
/// card comes round once more at the end, without changing its schedule again.
/// Practice goes through cards that aren't due, as often as the student
/// likes, and never changes when they come back.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let subjectID: Subject.ID?
    @State private var queue: [Flashcard]
    @State private var isPractice: Bool
    /// Cards already answered once in this sitting, so a second go doesn't reschedule them.
    @State private var answered: [Flashcard.ID: Bool] = [:]
    /// Cards practised since the sheet opened, so practising more brings new ones first.
    @State private var practised: Set<Flashcard.ID> = []
    @State private var position = 0
    @State private var showsAnswer = false
    @State private var editing: Flashcard?

    /// At most this many new answers in one sitting, so a review stays short.
    static let sittingSize = 30

    /// - Parameters:
    ///   - isPractice: Go through cards that aren't due, without changing when they come back.
    ///   - showsAnswer: Start with the first answer showing, for screenshots.
    init(cards: [Flashcard], subjectID: Subject.ID? = nil, isPractice: Bool = false, showsAnswer: Bool = false) {
        self.subjectID = subjectID
        let sitting = Array(cards.prefix(Self.sittingSize))
        _queue = State(initialValue: sitting)
        _isPractice = State(initialValue: isPractice)
        _practised = State(initialValue: isPractice ? Set(sitting.map(\.id)) : [])
        _showsAnswer = State(initialValue: showsAnswer)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.separator).frame(height: 1)
            if position < queue.count {
                card(queue[position])
                    .padding(24)
                Spacer(minLength: 0)
                controls(for: queue[position])
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            } else {
                finished
            }
        }
        .frame(width: 600, height: 480)
        .background(Theme.windowBackground)
        .sheet(item: $editing) { card in
            CardEditor(card: card) { saved in
                if let index = queue.firstIndex(where: { $0.id == saved.id }) { queue[index] = saved }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if position < queue.count {
                Text("\(position + 1) of \(queue.count)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
    }

    private func card(_ card: Flashcard) -> some View {
        let subject = model.subject(card.subjectID)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(verbatim: subject?.name ?? "")
                    .font(.system(size: 11.5, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(subject?.tintForeground ?? Theme.secondaryText)
                Spacer()
                Menu {
                    Button("Edit Card…") { editing = card }
                    Button("Delete Card", role: .destructive) { delete(card) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Card actions")
            }
            Text(card.question)
                .font(.system(size: 21, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if showsAnswer {
                Rectangle().fill(Theme.separator).frame(height: 1)
                Text(card.answer)
                    .font(.system(size: 16))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let quote = card.quote, !quote.isEmpty {
                    Text("“\(quote)”")
                        .font(.system(size: 12.5).italic())
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = card.sourceName {
                    HStack(spacing: 6) {
                        Text("From \(source)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let url = sourceURL(of: card) {
                            Button("Open") { model.open(url) }
                                .buttonStyle(.folioLink)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill((subject?.color ?? Theme.accent).opacity(0.1)))
        .animation(Theme.motion(), value: showsAnswer)
    }

    @ViewBuilder
    private func controls(for card: Flashcard) -> some View {
        if showsAnswer {
            HStack(spacing: 12) {
                Button {
                    answer(card, knewIt: false)
                } label: {
                    Label("Didn't Know", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(FilledButtonStyle(kind: .ghost, height: 38, fullWidth: true))
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help(isPractice ? "It comes round once more at the end (←)" : "Back to the first box: it comes round again tomorrow (←)")
                Button {
                    answer(card, knewIt: true)
                } label: {
                    Label("Knew It", systemImage: "checkmark")
                }
                .buttonStyle(FilledButtonStyle(kind: .primary, height: 38, fullWidth: true))
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help(isPractice ? "Next card (→)" : "Up a box: it comes back later (→)")
            }
        } else {
            Button("Show Answer") { showsAnswer = true }
                .buttonStyle(FilledButtonStyle(kind: .primary, height: 38, fullWidth: true))
                .keyboardShortcut(.space, modifiers: [])
        }
    }

    private var title: String {
        let subject = subjectID.flatMap { model.subject($0)?.name }
        if isPractice {
            return subject.map { String(localized: "Practice · \($0)") } ?? String(localized: "Practice")
        }
        return subject.map { String(localized: "Review · \($0)") } ?? String(localized: "Review")
    }

    private var finished: some View {
        let firsts = answered.values
        let knew = firsts.filter { $0 }.count
        let due = model.dueCards(in: subjectID)
        let canPractise = !model.practiceCards(in: subjectID).isEmpty
        return VStack(spacing: 14) {
            Spacer()
            IconTile(systemName: "checkmark", foreground: Theme.success, background: Theme.success.opacity(0.16), size: 52, cornerRadius: 14, symbolSize: 22)
            Text(queue.isEmpty ? (isPractice ? "Nothing to practise" : "Nothing to review") : (isPractice ? "Practice done" : "Done for now"))
                .font(.system(size: 20, weight: .semibold))
            if !firsts.isEmpty {
                Text(isPractice
                     ? String(localized: "You knew \(knew) of \(firsts.count) the first time. Practice doesn't change when cards come back.")
                     : String(localized: "You knew \(knew) of \(firsts.count) the first time. Cards you missed come back tomorrow."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                if !due.isEmpty {
                    Button("Review \(due.count) More") { start(due, practice: false) }
                        .buttonStyle(.folioGhost)
                } else if canPractise {
                    Button(isPractice ? "Practise More" : "Keep Practising") { practiseMore() }
                        .buttonStyle(.folioGhost)
                        .shotTarget("keep-practising")
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.folioPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func answer(_ card: Flashcard, knewIt: Bool) {
        if answered[card.id] == nil {
            answered[card.id] = knewIt
            // Practice never moves a card between boxes.
            let updated = isPractice ? card : model.answer(card, knewIt: knewIt)
            queue[position] = updated
            // One more go at the end of this sitting.
            if !knewIt { queue.append(updated) }
        }
        showsAnswer = false
        position += 1
    }

    /// Starts again with new cards, in the same sheet.
    private func start(_ cards: [Flashcard], practice: Bool) {
        queue = Array(cards.prefix(Self.sittingSize))
        if practice { practised.formUnion(queue.map(\.id)) }
        isPractice = practice
        answered = [:]
        position = 0
        showsAnswer = false
    }

    /// The next cards to practise: ones not practised yet, then round again.
    private func practiseMore() {
        let fresh = model.practiceCards(in: subjectID, excluding: practised)
        if fresh.isEmpty { practised = [] }
        start(fresh.isEmpty ? model.practiceCards(in: subjectID) : fresh, practice: true)
    }

    private func delete(_ card: Flashcard) {
        model.deleteCards([card.id])
        queue.removeAll { $0.id == card.id }
        showsAnswer = false
    }

    /// The file a card came from, when it's still in the library.
    private func sourceURL(of card: Flashcard) -> URL? {
        guard let name = card.sourceName else { return nil }
        return (model.libraryFiles + model.recentlySorted).first { $0.name == name && $0.subjectID == card.subjectID }?.url
    }
}

/// Adds a card by hand, or changes one.
struct CardEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let existing: Flashcard?
    var onSave: ((Flashcard) -> Void)?
    @State private var subjectID: Subject.ID?
    @State private var question: String
    @State private var answer: String

    init(card: Flashcard?, subjectID: Subject.ID? = nil, onSave: ((Flashcard) -> Void)? = nil) {
        existing = card
        self.onSave = onSave
        _subjectID = State(initialValue: card?.subjectID ?? subjectID)
        _question = State(initialValue: card?.question ?? "")
        _answer = State(initialValue: card?.answer ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Card" : "Edit Card")
                .font(.system(size: 15, weight: .semibold))
            Form {
                Picker("Subject", selection: $subjectID) {
                    ForEach(model.subjects) { subject in
                        Text(verbatim: subject.name).tag(Optional(subject.id))
                    }
                }
                TextField("Question", text: $question, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Answer", text: $answer, axis: .vertical)
                    .lineLimit(2...6)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add Card" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(subjectID == nil || question.trimmingCharacters(in: .whitespaces).isEmpty || answer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { subjectID = subjectID ?? model.subjects.first?.id }
    }

    private func save() {
        guard let subjectID else { return }
        var card = existing ?? Flashcard(subjectID: subjectID, question: "", answer: "", origin: .student, due: model.calendar.startOfDay(for: .now))
        card.subjectID = subjectID
        card.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        card.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveCards([card])
        onSave?(card)
        dismiss()
    }
}
