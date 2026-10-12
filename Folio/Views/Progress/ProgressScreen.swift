import Charts
import SwiftUI
import FolioKit

/// How things are going, honestly: the week so far, weeks ahead with too much
/// on, marks in each subject, study time against the plan and against what's
/// due, and past terms.
struct ProgressScreen: View {
    @Environment(AppModel.self) private var model
    @State private var term: TermRequest?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 300)) { context in
            let now = context.date
            Screen(title: "Progress", subtitle: subtitle(at: now)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack(alignment: .top, spacing: 16) {
                            WeekSoFarCard(now: now)
                            MarksSummaryCard()
                            ComingUpCard(now: now)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        let warnings = model.workloadWarnings(now: now)
                        if !warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle("Weeks ahead")
                                ForEach(warnings) { warning in
                                    WorkloadCard(warning: warning)
                                }
                            }
                        }

                        MarksSection()
                        StudyTimeSection(now: now)

                        let terms = model.pastTerms(now: now)
                        if !terms.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle("Past terms")
                                VStack(spacing: 0) {
                                    ForEach(terms) { request in
                                        Button {
                                            term = request
                                        } label: {
                                            HStack {
                                                Image(systemName: "archivebox")
                                                    .foregroundStyle(Theme.secondaryText)
                                                Text(request.title)
                                                    .font(.system(size: 13.5, weight: .medium))
                                                Spacer()
                                                Text("\(request.subjectIDs.count) subjects")
                                                    .font(.system(size: 12.5))
                                                    .foregroundStyle(Theme.secondaryText)
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(Theme.tertiaryText)
                                            }
                                            .padding(.vertical, 11)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        if request.id != terms.last?.id {
                                            Rectangle().fill(Theme.separator).frame(height: 1)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
                            }
                        }
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
        .sheet(item: $term) { request in
            TermSummarySheet(request: request)
        }
    }

    /// "78% average · 3h 5m studied this week".
    private func subtitle(at now: Date) -> String {
        var parts: [String] = []
        if let average = model.overallStanding.average {
            parts.append(String(localized: "\(ProgressFormat.percent(average)) average"))
        }
        let studied = model.studyMinutes(inWeekOf: now).recorded
        if studied > 0 { parts.append(String(localized: "\(StudyFormat.duration(minutes: studied)) studied this week")) }
        return parts.joined(separator: " · ")
    }
}

/// How a busy stretch is described, on Progress and Today.
enum WorkloadText {
    /// "Busy week: 26 Oct – 1 Nov", or "Busy weeks: …" for a stretch.
    static func title(_ warning: WorkloadCheck.Warning, calendar: Calendar) -> String {
        let range = ProgressFormat.week(warning.week, calendar: calendar)
        return warning.week.duration > 8 * 86_400 ? String(localized: "Busy weeks: \(range)") : String(localized: "Busy week: \(range)")
    }

    static func reason(_ warning: WorkloadCheck.Warning) -> String {
        let crowded = String(localized: "\(warning.due.count) things are due.")
        guard warning.isTooMuchWork else { return crowded }
        let work = String(localized: "About \(StudyFormat.duration(minutes: warning.workMinutes)) of work for assessments in the busiest week, and a usual week has room for \(StudyFormat.duration(minutes: warning.roomMinutes)) of study.")
        return warning.isCrowded ? "\(work) \(crowded)" : work
    }
}

/// Numbers as the student reads them.
enum ProgressFormat {
    /// "78%".
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "26 Oct – 1 Nov".
    static func week(_ week: DateInterval, calendar: Calendar) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
        return (week.start..<last).formatted(.interval.day().month(.abbreviated))
    }
}

/// A thin bar: `value` of `total`, in a colour.
struct AmountBar: View {
    let value: Double
    let total: Double
    var color: Color = Theme.accent
    /// Draws the empty part too. Off for a bar laid over another.
    var showsTrack = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(showsTrack ? 0.08 : 0))
                Capsule()
                    .fill(color)
                    .frame(width: total > 0 ? proxy.size.width * min(1, max(0, value / total)) : 0)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: The cards at the top

/// This week's study against the plan, with the way into the weekly review.
private struct WeekSoFarCard: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let review = model.weekReview(startingOn: model.weekStart(containing: now), now: now)
        VStack(alignment: .leading, spacing: 12) {
            IconTile(systemName: "chart.bar.fill", foreground: Theme.warning, background: Theme.warning.opacity(0.16), size: 40, cornerRadius: 11, symbolSize: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(StudyFormat.duration(minutes: review.studied))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Studied this week")
                    .font(.system(size: 13, weight: .medium))
                Text(review.planned > 0
                     ? String(localized: "Of \(StudyFormat.duration(minutes: review.planned)) planned.")
                     : String(localized: "Nothing planned this week yet."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            if review.planned > 0 {
                AmountBar(value: Double(review.studied), total: Double(review.planned), color: Theme.warning)
            }
            Spacer(minLength: 0)
            Button("Review Your Week…") { model.isShowingWeeklyReview = true }
                .buttonStyle(.folioGhost)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
    }
}

/// The average across every subject's marks.
private struct MarksSummaryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let standing = model.overallStanding
        VStack(alignment: .leading, spacing: 12) {
            IconTile(systemName: "checkmark.seal.fill", foreground: Theme.success, background: Theme.success.opacity(0.16), size: 40, cornerRadius: 11, symbolSize: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(standing.average.map(ProgressFormat.percent) ?? "–")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Average mark")
                    .font(.system(size: 13, weight: .medium))
                Text(standing.points.isEmpty
                     ? String(localized: "Marks appear here when marked work comes back.")
                     : String(localized: "From \(standing.points.count) marks, each counted by what it's worth."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
    }
}

/// What's due in the next seven days, and how much study is planned for it.
private struct ComingUpCard: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let due = model.upcomingAssessments(within: 7, now: now)
        VStack(alignment: .leading, spacing: 12) {
            IconTile(systemName: "calendar", foreground: Theme.accentText, background: Theme.accent.opacity(0.16), size: 40, cornerRadius: 11, symbolSize: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(due.count.formatted())
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Due in the next 7 days")
                    .font(.system(size: 13, weight: .medium))
                Text(due.isEmpty ? String(localized: "A good time to get ahead.") : due.prefix(3).map(\.title).formatted(.list(type: .and)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.cardBackground))
    }
}

// MARK: Weeks ahead

/// A week with too much on, and the offer to start some of it earlier.
struct WorkloadCard: View {
    @Environment(AppModel.self) private var model
    let warning: WorkloadCheck.Warning
    @State private var started = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: "exclamationmark.triangle.fill", foreground: Theme.warning, background: Theme.warning.opacity(0.16))
            VStack(alignment: .leading, spacing: 6) {
                Text(WorkloadText.title(warning, calendar: model.calendar))
                    .font(.system(size: 15, weight: .semibold))
                Text(WorkloadText.reason(warning))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !warning.due.isEmpty {
                    Text("Due: \(warning.due.map { "\($0.title) (\($0.due.formatted(.dateTime.weekday(.abbreviated))))" }.formatted(.list(type: .and)))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if started {
                    Label("Started earlier. Plan My Week now spreads that work into the weeks before.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.success)
                        .padding(.top, 4)
                } else if !warning.startEarlier.isEmpty {
                    Text("Start earlier on \(warning.startEarlier.map { "\($0.title) (\(startText($0.from)))" }.formatted(.list(type: .and)))?")
                        .font(.system(size: 12.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    HStack(spacing: 10) {
                        Button("Start Earlier") {
                            withAnimation(Theme.motion()) {
                                model.startEarlier(warning.startEarlier)
                                started = true
                            }
                        }
                        .buttonStyle(.folioPrimary)
                        .shotTarget("start-earlier")
                        Button("Not Now") {
                            withAnimation(Theme.motion()) { model.dismissWarning(warning) }
                        }
                        .buttonStyle(.folioGhost)
                    }
                    .padding(.top, 4)
                } else {
                    Button("Not Now") {
                        withAnimation(Theme.motion()) { model.dismissWarning(warning) }
                    }
                    .buttonStyle(.folioGhost)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.list).strokeBorder(Theme.warning.opacity(0.25), lineWidth: 1))
    }

    /// "from today", or "from Mon 19 Oct".
    private func startText(_ date: Date) -> String {
        model.calendar.isDateInToday(date)
            ? String(localized: "from today")
            : String(localized: "from \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
    }
}

// MARK: Marks

/// Every subject's marks over time, then each subject's standing.
private struct MarksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let standings = model.subjects.map { ($0, model.standing(of: $0.id)) }
        let points = standings.flatMap(\.1.points)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Marks")
            VStack(alignment: .leading, spacing: 16) {
                if points.isEmpty {
                    Text("No marks yet. When marked work comes back, add the mark to its assessment, or drop the marked file on Folio and it will offer to.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarksChart(points: points)
                        .frame(height: 200)
                }
                VStack(spacing: 0) {
                    ForEach(standings, id: \.0.id) { subject, standing in
                        StandingRow(subject: subject, standing: standing)
                        if subject.id != standings.last?.0.id {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        }
    }
}

/// Marks over time, as percentages, one line for each subject.
struct MarksChart: View {
    @Environment(AppModel.self) private var model
    let points: [Standing.Point]
    /// Names the subjects under the chart. Off when there's only one.
    var showsLegend = true

    var body: some View {
        let subjects = model.profile.subjects.filter { subject in points.contains { $0.subjectID == subject.id } }
        Chart(points) { point in
            let name = model.subject(point.subjectID)?.name ?? ""
            LineMark(x: .value("Date", point.date), y: .value("Mark", point.fraction * 100))
                .foregroundStyle(by: .value("Subject", name))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Date", point.date), y: .value("Mark", point.fraction * 100))
                .foregroundStyle(by: .value("Subject", name))
                .accessibilityLabel(point.title)
                .accessibilityValue(ProgressFormat.percent(point.fraction))
        }
        .chartForegroundStyleScale(domain: subjects.map(\.name), range: subjects.map(\.color))
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text(ProgressFormat.percent(Double(percent) / 100)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Theme.secondaryText)
            }
        }
        .chartLegend(showsLegend ? .visible : .hidden)
        .chartLegend(position: .bottom, alignment: .leading)
    }
}

/// A subject's average, how much of the course is marked, and its latest mark.
private struct StandingRow: View {
    let subject: Subject
    let standing: Standing

    var body: some View {
        HStack(spacing: 12) {
            SubjectDot(color: subject.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.name)
                    .font(.system(size: 13.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Text(standing.average.map(ProgressFormat.percent) ?? standing.grades.first?.grade ?? "–")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(standing.isEmpty ? Theme.tertiaryText : Theme.primaryText)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// "3 marks · 45% of the course marked · last: Essay 18/20".
    private var detail: String {
        guard !standing.isEmpty else { return String(localized: "No marks yet") }
        var parts = [String(localized: "\(standing.points.count + standing.grades.count) marks")]
        if let weight = standing.weightMarked {
            parts.append(String(localized: "\(ProgressFormat.percent(weight / 100)) of the course marked"))
        }
        if let last = standing.points.last {
            parts.append(String(localized: "last: \(last.title) \(ProgressFormat.percent(last.fraction))"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: Study time

/// The last four weeks' study in each subject, against the plan, with a
/// note for subjects getting much less time than their share of what's due.
private struct StudyTimeSection: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let times = model.studyTimes(now: now)
        let total = times.reduce(0) { $0 + $1.studied }
        let most = max(1, times.map { max($0.studied, $0.planned) }.max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Study time, last 4 weeks")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(times) { time in
                    if let subject = model.subject(time.subjectID) {
                        StudyTimeRow(subject: subject, time: time, most: most, isBehind: time.isBehind(totalStudied: total))
                        if time.id != times.last?.id {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                }
                Text(total == 0
                     ? "Finish sessions with the timer, or mark them done in the Planner, and your study shows here."
                     : "Darker bars are time studied; lighter ones, time planned. Shares compare your study with the work due in the next six weeks.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        }
    }
}

private struct StudyTimeRow: View {
    let subject: Subject
    let time: StudyTime
    let most: Int
    let isBehind: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SubjectDot(color: subject.color)
                Text(subject.name)
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                Text(time.planned > 0
                     ? String(localized: "\(StudyFormat.duration(minutes: time.studied)) of \(StudyFormat.duration(minutes: time.planned))")
                     : StudyFormat.duration(minutes: time.studied))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
            ZStack(alignment: .leading) {
                AmountBar(value: Double(time.planned), total: Double(most), color: subject.color.opacity(0.3))
                AmountBar(value: Double(time.studied), total: Double(most), color: subject.color, showsTrack: false)
            }
            if isBehind {
                Label(String(localized: "\(ProgressFormat.percent(time.dueShare)) of the work due soon, but \(ProgressFormat.percent(time.studyShare)) of your study."), systemImage: "arrow.down.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
