import SwiftUI
import FolioKit

/// A subject's marks over time and its study lately, on the subject's page.
struct SubjectProgressSection: View {
    @Environment(AppModel.self) private var model
    let subject: Subject

    var body: some View {
        let standing = model.standing(of: subject.id)
        let times = model.studyTimes()
        let total = times.reduce(0) { $0 + $1.studied }
        let time = times.first { $0.subjectID == subject.id }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Progress")
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Marks", systemImage: "checkmark.seal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(subject.tintForeground)
                        .textCase(.uppercase)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(standing.average.map(ProgressFormat.percent) ?? standing.grades.first?.grade ?? "–")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(detail(standing))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if standing.points.count >= 2 {
                        MarksChart(points: standing.points, showsLegend: false)
                            .frame(height: 130)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.cardBackground))

                VStack(alignment: .leading, spacing: 10) {
                    Label("Study, last 4 weeks", systemImage: "clock")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(subject.tintForeground)
                        .textCase(.uppercase)
                    Text(StudyFormat.duration(minutes: time?.studied ?? 0))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let time, time.planned > 0 {
                        Text("Of \(StudyFormat.duration(minutes: time.planned)) planned.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                        AmountBar(value: Double(time.studied), total: Double(time.planned), color: subject.color)
                    }
                    if let time, time.isBehind(totalStudied: total) {
                        Label(String(localized: "\(ProgressFormat.percent(time.dueShare)) of the work due soon, but \(ProgressFormat.percent(time.studyShare)) of your study."), systemImage: "arrow.down.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .frame(width: 300, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.cardBackground))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "3 marks · 45% of the course marked", or "No marks yet".
    private func detail(_ standing: Standing) -> String {
        guard !standing.isEmpty else { return String(localized: "No marks yet") }
        var parts = [String(localized: "\(standing.points.count + standing.grades.count) marks")]
        if let weight = standing.weightMarked {
            parts.append(String(localized: "\(ProgressFormat.percent(weight / 100)) of the course marked"))
        }
        return parts.joined(separator: " · ")
    }
}

/// On Today: the week's review when it's ready, and the next busy week, each as a quiet line.
struct ProgressPrompts: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let reviewWaiting = model.isWeeklyReviewWaiting(now: now)
        let soon = model.calendar.date(byAdding: .day, value: 21, to: now) ?? now
        let warning = model.workloadWarnings(now: now).first { $0.week.start < soon }
        if reviewWaiting || warning != nil {
            VStack(spacing: 10) {
                if reviewWaiting {
                    PromptRow(
                        systemImage: "chart.bar.fill", tint: Theme.accent,
                        title: String(localized: "Your week in review is ready"),
                        detail: String(localized: "See how it went, and plan the next one."),
                        action: String(localized: "Review")
                    ) {
                        model.isShowingWeeklyReview = true
                    }
                }
                if let warning {
                    PromptRow(
                        systemImage: "exclamationmark.triangle.fill", tint: Theme.warning,
                        title: WorkloadText.title(warning, calendar: model.calendar),
                        detail: warning.startEarlier.isEmpty
                            ? WorkloadText.reason(warning)
                            : String(localized: "Starting some of the work earlier would help."),
                        action: String(localized: "See Progress")
                    ) {
                        model.destination = .progress
                    }
                }
            }
        }
    }
}

private struct PromptRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: systemImage, foreground: tint, background: tint.opacity(0.16), size: 34, cornerRadius: 10, symbolSize: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action, action: perform)
                .buttonStyle(.folioGhost)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
    }
}
