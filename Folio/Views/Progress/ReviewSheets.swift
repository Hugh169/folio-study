import SwiftUI
import FolioKit

/// The week looked back on: study against the plan, how the sessions went,
/// what was handed in or missed, marks that came back, then what's due next
/// week, with a way to plan it.
struct WeeklyReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let weekStart: Date?
    @State private var planned: Int?

    /// - Parameter weekStart: The week to review, or the one just finished.
    init(weekStart: Date? = nil) {
        self.weekStart = weekStart
    }

    var body: some View {
        let start = weekStart ?? model.reviewWeekStart()
        let review = model.weekReview(startingOn: start)
        let nextWeek = DateInterval(start: review.week.end, duration: 7 * 86_400)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your week in review")
                    .font(.system(size: 17, weight: .semibold))
                Text(ProgressFormat.week(review.week, calendar: model.calendar))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding([.top, .horizontal], 24)
            .padding(.bottom, 14)
            Rectangle().fill(Theme.separator).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(review.planned > 0
                             ? String(localized: "You studied \(StudyFormat.duration(minutes: review.studied)) of \(StudyFormat.duration(minutes: review.planned)) planned.")
                             : String(localized: "You studied \(StudyFormat.duration(minutes: review.studied)), with nothing planned."))
                            .font(.system(size: 15, weight: .medium))
                        if review.planned > 0 {
                            AmountBar(value: Double(review.studied), total: Double(review.planned), color: Theme.warning)
                        }
                        Text(sessionsText(review))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !review.bySubject.isEmpty {
                        ReviewList(title: "By subject") {
                            ForEach(review.bySubject) { line in
                                if let subject = model.subject(line.subjectID) {
                                    HStack {
                                        SubjectDot(color: subject.color)
                                        Text(subject.name)
                                        Spacer()
                                        Text(line.planned > 0
                                             ? String(localized: "\(StudyFormat.duration(minutes: line.studied)) of \(StudyFormat.duration(minutes: line.planned))")
                                             : StudyFormat.duration(minutes: line.studied))
                                            .foregroundStyle(Theme.secondaryText)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                    }

                    if !review.handedIn.isEmpty || !review.overdue.isEmpty || !review.marksBack.isEmpty || review.todosDone > 0 {
                        ReviewList(title: "Work") {
                            ForEach(review.handedIn) { assessment in
                                ReviewLine(systemImage: "checkmark.circle.fill", color: Theme.success, text: String(localized: "Handed in \(assessment.title)"))
                            }
                            ForEach(review.overdue) { assessment in
                                ReviewLine(
                                    systemImage: "exclamationmark.circle.fill", color: Theme.warning,
                                    text: String(localized: "\(assessment.title) was due \(assessment.due.formatted(.dateTime.weekday(.wide)))."),
                                    action: String(localized: "Handed In")
                                ) {
                                    withAnimation(Theme.motion()) { model.setStatus(.submitted, of: assessment) }
                                }
                            }
                            ForEach(review.marksBack) { assessment in
                                ReviewLine(systemImage: "star.circle.fill", color: Theme.accentText, text: String(localized: "Mark back for \(assessment.title): \(assessment.mark?.text ?? "")"))
                            }
                            if review.todosDone > 0 {
                                ReviewLine(systemImage: "checklist", color: Theme.secondaryText, text: String(localized: "Ticked off \(review.todosDone) to-dos"))
                            }
                        }
                    }

                    ReviewList(title: "Next week, \(ProgressFormat.week(nextWeek, calendar: model.calendar))") {
                        if review.dueNext.isEmpty {
                            ReviewLine(systemImage: "calendar", color: Theme.secondaryText, text: String(localized: "Nothing due."))
                        }
                        ForEach(review.dueNext) { assessment in
                            ReviewLine(systemImage: assessment.kind.systemImage, color: model.subject(assessment.subjectID)?.color ?? Theme.accent, text: "\(assessment.title) · \(assessment.due.formatted(.dateTime.weekday(.wide)))")
                        }
                        ReviewLine(
                            systemImage: "clock",
                            color: Theme.secondaryText,
                            text: review.plannedNext > 0
                                ? String(localized: "\(StudyFormat.duration(minutes: review.plannedNext)) of study planned so far.")
                                : String(localized: "No study planned yet.")
                        )
                        if let planned {
                            Label(planned == 0 ? String(localized: "No free time left to plan that week.") : String(localized: "Added \(planned) study sessions."), systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.success)
                        }
                    }
                }
                .padding(24)
            }

            HStack {
                Spacer()
                Button("Plan Next Week") {
                    withAnimation(Theme.motion()) { planned = model.planWeek(containing: nextWeek.start) }
                }
                .buttonStyle(.folioGhost)
                .disabled(planned != nil)
                .shotTarget("plan-next-week")
                Button("Done") { dismiss() }
                    .buttonStyle(.folioPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 24)
            .padding(.top, 8)
        }
        .frame(width: 520, height: 640)
        .background(Theme.windowBackground)
        .onAppear { model.markWeekReviewed(start) }
    }

    /// "4 sessions done, 1 partly, 1 didn't start, 2 not recorded".
    private func sessionsText(_ review: WeekReview) -> String {
        var parts: [String] = []
        if review.done > 0 { parts.append(String(localized: "\(review.done) sessions done")) }
        if review.partly > 0 { parts.append(String(localized: "\(review.partly) partly done")) }
        if review.skipped > 0 { parts.append(String(localized: "\(review.skipped) didn't start")) }
        if review.notRecorded > 0 { parts.append(String(localized: "\(review.notRecorded) not recorded")) }
        return parts.isEmpty ? String(localized: "No sessions recorded.") : parts.formatted(.list(type: .and))
    }
}

/// A titled group of lines in a review.
private struct ReviewList<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.tertiaryText)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .font(.system(size: 13))
        }
    }
}

private struct ReviewLine: View {
    let systemImage: String
    let color: Color
    let text: String
    var action: String?
    var perform: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Spacer(minLength: 8)
                Button(action, action: perform)
                    .buttonStyle(.folioLink)
            }
        }
    }
}

/// A term looked back on, for each subject: time studied, marks, work handed in and files.
struct TermSummaryView: View {
    @Environment(AppModel.self) private var model
    let summary: TermSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                TermFigure(value: StudyFormat.duration(minutes: summary.studied), label: "studied")
                TermFigure(value: summary.standing.average.map(ProgressFormat.percent) ?? "–", label: "average mark")
                TermFigure(value: summary.lines.reduce(0) { $0 + $1.handedIn }.formatted(), label: "handed in")
                TermFigure(value: summary.files.formatted(), label: "files")
            }
            VStack(spacing: 0) {
                ForEach(summary.lines) { line in
                    if let subject = model.subject(line.subjectID) {
                        HStack(spacing: 10) {
                            SubjectDot(color: subject.color)
                            Text(subject.name)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text([StudyFormat.duration(minutes: line.studied), String(localized: "\(line.handedIn) handed in"), fileCountText(line.files)].joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                                .monospacedDigit()
                            Text(line.standing.average.map(ProgressFormat.percent) ?? line.standing.grades.first?.grade ?? "–")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                        if line.id != summary.lines.last?.id {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        }
    }
}

private struct TermFigure: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TermSummarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TermRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title)
                .font(.system(size: 17, weight: .semibold))
            ScrollView {
                TermSummaryView(summary: model.termSummary(request))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 520)
    }
}
