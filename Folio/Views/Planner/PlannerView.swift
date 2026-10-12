import SwiftUI
import FolioKit

struct PlannerView: View {
    typealias Mode = PlannerMode

    @Environment(AppModel.self) private var model
    @State private var anchor = Date.now
    @State private var planMessage: String?
    @State private var isAddingExams = false
    @State private var isAddingAssessment = false
    @State private var creatingSession: NewSessionRequest?

    private var mode: Mode {
        get { model.plannerMode }
        nonmutating set { model.plannerMode = newValue }
    }

    var body: some View {
        @Bindable var model = model
        Screen(title: "Planner", subtitle: rangeTitle) {
            HStack(spacing: 0) {
                ScrollView {
                    calendar
                        .padding(EdgeInsets(top: 8, leading: 8, bottom: 20, trailing: 16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PlannerSidePanel(weekStart: weekStart, message: $planMessage)
            }
        }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Menu {
                    Button("New Study Session…") { creatingSession = NewSessionRequest(start: newSessionStart) }
                    Divider()
                    Button("New Assessment…") { isAddingAssessment = true }
                    Button("Add Exams…") { isAddingExams = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a study session, an assessment or your exams")
            }
            ToolbarItem {
                ControlGroup {
                    Button { step(by: -1) } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .help("Previous (⌘←)")
                    Button("Today") {
                        withAnimation(Theme.motion()) { anchor = .now }
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("Today (⌘T)")
                    Button { step(by: 1) } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("Next (⌘→)")
                }
                .disabled(mode == .assessments)
            }
            ToolbarItem {
                Picker("View", selection: $model.plannerMode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .sheet(isPresented: $isAddingExams) {
            ExamsSheet()
        }
        .sheet(isPresented: $isAddingAssessment) {
            AssessmentSheet(assessment: nil)
        }
        .sheet(item: $creatingSession) { request in
            SessionSheet(session: nil, start: request.start)
        }
        .onChange(of: weekStart) {
            planMessage = nil
            model.loadEvents(around: weekStart)
        }
        .onAppear {
            showRequestedDate()
            model.loadEvents(around: weekStart)
        }
        .onChange(of: model.requestedPlannerDate) { showRequestedDate() }
    }

    /// Moves to a day another screen asked for, such as one tapped on Today.
    private func showRequestedDate() {
        guard let requested = model.requestedPlannerDate else { return }
        anchor = requested
        model.requestedPlannerDate = nil
    }

    @ViewBuilder private var calendar: some View {
        let now = Date.now
        switch mode {
        case .day:
            CalendarGrid(days: [model.calendar.startOfDay(for: anchor)], now: now)
        case .week:
            CalendarGrid(days: weekDays, now: now)
        case .month:
            MonthGrid(month: anchor, now: now) { day in
                anchor = day
                mode = .day
            }
        case .assessments:
            AssessmentList()
        }
    }

    private var weekStart: Date {
        model.weekStart(containing: anchor)
    }

    /// The next half hour when the planner shows today, or 4 pm on the day it shows.
    private var newSessionStart: Date {
        let now = Date.now
        if model.calendar.isDate(anchor, inSameDayAs: now) || anchor < now {
            let step: TimeInterval = 30 * 60
            return Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
        }
        return model.calendar.date(bySettingHour: 16, minute: 0, second: 0, of: anchor) ?? anchor
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { model.calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var rangeTitle: String {
        switch mode {
        case .day:
            let day = anchor.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            return model.weekName(for: anchor).map { "\(day) · \($0)" } ?? day
        case .week:
            let sunday = model.calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            let range = (weekStart..<sunday).formatted(.interval.day().month(.wide).year())
            // Midweek, so a week that starts on Sunday is named by its school week.
            let midweek = model.calendar.date(byAdding: .day, value: 3, to: weekStart) ?? weekStart
            return model.weekName(for: midweek).map { "\(range) · \($0)" } ?? range
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        case .assessments:
            return String(localized: "\(model.assessments.filter { !$0.isDone && $0.due >= .now }.count) coming up")
        }
    }

    private func step(by direction: Int) {
        let component: Calendar.Component = switch mode {
        case .day: .day
        case .week, .assessments: .weekOfYear
        case .month: .month
        }
        withAnimation(Theme.motion()) {
            anchor = model.calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
        }
    }
}

/// What's due soon, the Plan My Week card, and the legend.
private struct PlannerSidePanel: View {
    @Environment(AppModel.self) private var model
    let weekStart: Date
    @Binding var message: String?
    @State private var editing: Assessment?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle("Due soon", leadingInset: 0)
                    Spacer()
                    Button {
                        isAdding = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .help("Add an assessment")
                    .accessibilityLabel("New Assessment")
                }
                if upcoming.isEmpty {
                    Text("Nothing due in the next two weeks.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(upcoming) { assessment in
                            AssessmentRow(assessment: assessment, compact: true)
                                .assessmentActions(assessment, edit: { editing = assessment })
                            if assessment.id != upcoming.last?.id {
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }

            planCard

            Spacer(minLength: 0)

            HStack(spacing: 18) {
                LegendItem(color: Theme.accent.opacity(0.5), title: "Study")
                if model.profile.timetable != nil {
                    LegendItem(color: Color.white.opacity(0.14), title: "Classes")
                } else if model.school != nil {
                    LegendItem(color: Color.white.opacity(0.14), title: "School")
                }
            }
        }
        .padding(24)
        .frame(width: 300)
        .sheet(isPresented: $isAdding) {
            AssessmentSheet(assessment: nil)
        }
        .sheet(item: $editing) { assessment in
            AssessmentSheet(assessment: assessment)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.separator)
                .frame(width: 1)
        }
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            IconTile(systemName: "sparkles", foreground: Theme.accent, background: Theme.accent.opacity(0.16))
            VStack(alignment: .leading, spacing: 4) {
                Text("Plan my week")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.isCalendarConnected
                     ? "Works back from your assessments and exams, around your calendar. Sessions you made or changed stay put."
                     : "Works back from your assessments and exams, around school and your free time. Sessions you made or changed stay put.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Plan My Week", action: planWeek)
                .buttonStyle(FilledButtonStyle(kind: .primary, height: 36, fullWidth: true))
                .disabled(!canPlan)
            if let message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .transition(.opacity)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.cardBackground))
    }

    /// Weeks that are already over can't be planned.
    private var canPlan: Bool {
        let weekEnd = model.calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        return weekEnd > .now
    }

    private var upcoming: [Assessment] {
        model.overdueAssessments() + model.upcomingAssessments(within: 14)
    }

    private func planWeek() {
        let added = withAnimation(Theme.motion(.spring(duration: 0.5, bounce: 0.2))) {
            model.planWeek(containing: weekStart)
        }
        withAnimation(Theme.motion(.default)) {
            message = added == 0
                ? String(localized: "No free time left to plan this week.")
                : String(localized: "Added \(added) study sessions.")
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(title)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
    }
}
