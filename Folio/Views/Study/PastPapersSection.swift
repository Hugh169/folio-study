import SwiftUI
import FolioKit

/// A subject's past papers, newest first, each with its marking guidelines,
/// the last mark the student gave themselves, and Practise.
struct PastPapersSection: View {
    @Environment(AppModel.self) private var model
    let subject: Subject
    @State private var practising: PastPapers.Paper?

    var body: some View {
        let papers = model.papers(of: subject.id)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Past papers")
            if papers.isEmpty {
                Text("Past papers you drop on Folio appear here, paired with their marking guidelines, ready to practise against the clock.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(papers) { paper in
                        PaperRow(paper: paper, subject: subject) { practising = paper }
                        if paper.id != papers.last?.id {
                            Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 56)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
        }
        .sheet(item: $practising) { paper in
            PractiseSheet(paper: paper, subject: subject)
        }
    }
}

private struct PaperRow: View {
    @Environment(AppModel.self) private var model
    let paper: PastPapers.Paper
    let subject: Subject
    let practise: () -> Void

    var body: some View {
        let last = model.attempts(at: paper).first
        HStack(spacing: 14) {
            IconTile(systemName: paper.isGuidelinesOnly ? "checkmark.seal" : "doc.text", foreground: subject.tintForeground, background: subject.tintBackground, symbolSize: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(paper.title)
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 6) {
                    Text(paper.file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !paper.guidelines.isEmpty {
                        Text("·")
                        Label("Marking guidelines", systemImage: "checkmark.seal")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Theme.success)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 12)
            if let last {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(last.mark?.text ?? StudyFormat.duration(minutes: last.minutes))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                    Text(last.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Last practised \(last.date.formatted(date: .abbreviated, time: .omitted))"))
            }
            if paper.isGuidelinesOnly {
                Button("Open") { model.open(paper.file.url) }
                    .buttonStyle(.folioLink)
            } else {
                Button("Practise", action: practise)
                    .buttonStyle(.folioGhost)
            }
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button("Open Paper") { model.open(paper.file.url) }
            ForEach(paper.guidelines, id: \.self) { guide in
                Button("Open \(guide.name)") { model.open(guide.url) }
            }
        }
    }
}

/// Sets the clock for a past paper: its own working time when Folio could
/// read it, or a time the student picks. Then opens the paper and starts the timer.
struct PractiseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let paper: PastPapers.Paper
    let subject: Subject
    @State private var minutes = 60

    var body: some View {
        let working = model.workingMinutes(of: paper)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: "doc.text", foreground: subject.tintForeground, background: subject.tintBackground)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Practise \(paper.title)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(paper.file.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(working.map { String(localized: "The paper allows \(StudyFormat.duration(minutes: $0)). Do it all, or set a shorter time for a section.") }
                 ?? String(localized: "Set how long you'll spend. A whole paper is usually two or three hours."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Stepper(value: $minutes, in: 5...300, step: 5) {
                Text(StudyFormat.duration(minutes: minutes))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
            }
            Text(paper.guidelines.isEmpty
                 ? "When you finish, Folio asks for your mark. It hasn't found marking guidelines for this paper yet."
                 : "When you finish, Folio opens the marking guidelines and asks for your mark.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    model.practise(paper, minutes: minutes, subjectID: subject.id)
                    openWindow(id: FocusWindow.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.focus != nil)
            }
            if model.focus != nil {
                Text("Finish the session that's running first.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { minutes = working ?? 60 }
    }
}

/// A subject's flashcards in brief, for its page.
struct SubjectCardsCard: View {
    @Environment(AppModel.self) private var model
    let subject: Subject
    @State private var reviewing: ReviewRequest?
    @State private var isMaking = false

    var body: some View {
        let cards = model.cards(of: subject.id)
        let due = model.dueCards(in: subject.id)
        VStack(alignment: .leading, spacing: 4) {
            Label("Flashcards", systemImage: "rectangle.on.rectangle.angled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(subject.tintForeground)
                .textCase(.uppercase)
                .padding(.bottom, 4)
            Text(cards.isEmpty ? String(localized: "No cards yet") : String(localized: "\(due.count) to review"))
                .font(.system(size: 15, weight: .semibold))
            Text(cards.isEmpty ? String(localized: "Make some from your notes.") : [String(localized: "\(cards.count) cards"), String(localized: "\(cards.filter(\.isLearnt).count) learnt")].joined(separator: " · "))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 4) {
                if !due.isEmpty {
                    Button("Review") { reviewing = ReviewRequest(cards: due, subjectID: subject.id) }
                        .buttonStyle(.folioLink)
                }
                Button("Make Cards…") { isMaking = true }
                    .buttonStyle(.folioLink)
            }
            .padding(.leading, -4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(subject.color.opacity(0.12)))
        .sheet(item: $reviewing) { request in
            ReviewSheet(cards: request.cards, subjectID: request.subjectID)
        }
        .sheet(isPresented: $isMaking) {
            MakeCardsSheet(subjectID: subject.id)
        }
    }
}
