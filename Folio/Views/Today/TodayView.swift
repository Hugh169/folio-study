import SwiftUI
import FolioKit

/// The screen Folio opens on: the week at a glance, the next study session
/// with what it needs, what's due soon, today's classes, a few numbers, the
/// first things to set up, and every subject.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Assessment?
    @State private var isAddingAssessment = false
    @State private var isAddingExams = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            Screen(verbatimTitle: greeting(at: now), subtitle: subtitle(at: now)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        WeekStrip(now: now)

                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 28) {
                                NextUpCard(session: model.nextSession(after: now), now: now)
                                ProgressPrompts(now: now)
                                dueSoon(now: now)
                                SetupChecklist()
                                if !model.recentlySorted.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        SectionTitle("Recently sorted")
                                        RecentFilesList(files: Array(model.recentlySorted.prefix(4)))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            VStack(alignment: .leading, spacing: 28) {
                                TodayStats(now: now)
                                ClassesToday(classes: model.classes(on: now), now: now)
                                if !model.needsReview.isEmpty || !model.assessmentSuggestions.isEmpty {
                                    InboxSummary()
                                }
                            }
                            .frame(width: 320, alignment: .topLeading)
                        }

                        if !model.subjects.isEmpty {
                            SubjectGrid(now: now)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 1240, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                AddFilesButton()
            }
        }
        .sheet(item: $editing) { assessment in
            AssessmentSheet(assessment: assessment)
        }
        .sheet(isPresented: $isAddingAssessment) {
            AssessmentSheet(assessment: nil)
        }
        .sheet(isPresented: $isAddingExams) {
            ExamsSheet()
        }
    }

    /// "Good morning, Sam", or without a name when the student didn't give one.
    private func greeting(at now: Date) -> String {
        let hour = model.calendar.component(.hour, from: now)
        let name = model.profile.studentName?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (hour, name.isEmpty) {
        case (..<12, true): return String(localized: "Good morning")
        case (..<12, false): return String(localized: "Good morning, \(name)")
        case (..<18, true): return String(localized: "Good afternoon")
        case (..<18, false): return String(localized: "Good afternoon, \(name)")
        case (_, true): return String(localized: "Good evening")
        case (_, false): return String(localized: "Good evening, \(name)")
        }
    }

    /// "Saturday 10 October · Week A".
    private func subtitle(at now: Date) -> String {
        let day = now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return model.weekName(for: now).map { "\(day) · \($0)" } ?? day
    }

    @ViewBuilder
    private func dueSoon(now: Date) -> some View {
        let upcoming = model.overdueAssessments(now: now) + model.upcomingAssessments(within: 14, now: now)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Due soon")
                Spacer()
                if !model.assessments.isEmpty {
                    Button("See All") {
                        model.plannerMode = .assessments
                        model.destination = .planner
                    }
                    .buttonStyle(.folioLink)
                }
            }
            if upcoming.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(
                        systemName: model.assessments.isEmpty ? "calendar.badge.plus" : "checkmark.seal",
                        foreground: model.assessments.isEmpty ? Theme.warning : Theme.success,
                        background: (model.assessments.isEmpty ? Theme.warning : Theme.success).opacity(0.16)
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.assessments.isEmpty ? "No tasks or exams yet" : "Nothing due in the next two weeks")
                            .font(.system(size: 14, weight: .medium))
                        Text(model.assessments.isEmpty
                             ? "Add them here, or drop a task sheet on Folio and it will offer to add it."
                             : "A good time to get ahead on something.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("New Assessment…") { isAddingAssessment = true }
                                .buttonStyle(.folioGhost)
                            Button("Add Exams…") { isAddingExams = true }
                                .buttonStyle(.folioGhost)
                        }
                        .padding(.top, 9)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            } else {
                VStack(spacing: 0) {
                    ForEach(upcoming) { assessment in
                        AssessmentRow(assessment: assessment)
                            .padding(.horizontal, 16)
                            .assessmentActions(assessment, edit: { editing = assessment })
                        if assessment.id != upcoming.last?.id {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 1)
                                .padding(.leading, 60)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
        }
    }
}

/// The study session on now or next, with its plan, its files and a Start
/// button, or a way to plan the week when nothing's planned. While the timer
/// runs, it says so and brings the timer back.
private struct NextUpCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let session: StudySession?
    let now: Date
    @State private var planning: StudySession?

    var body: some View {
        if let focus = model.focus, let subject = model.subject(focus.subjectID) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "timer", foreground: subject.tintForeground, background: subject.tintBackground)
                VStack(alignment: .leading, spacing: 3) {
                    Text(focus.isOver ? "Time's up" : focus.isPaused ? "Paused" : "Studying now")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(subject.tintForeground)
                        .textCase(.uppercase)
                    Text(focus.title.map { "\(subject.name) · \($0)" } ?? subject.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text(focus.isOver ? String(localized: "Say how it went to record it.") : String(localized: "\(Int((focus.remaining(at: now) / 60).rounded(.up))) minutes left"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 12)
                Button("Show Timer") { openWindow(id: FocusWindow.id) }
                    .buttonStyle(.folioPrimary)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(subject.color.opacity(0.14)))
        } else if let session, let subject = model.subject(session.subjectID) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemName: "book", foreground: subject.tintForeground, background: subject.tintBackground)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.start <= now ? "Studying now" : "Next up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(subject.tintForeground)
                            .textCase(.uppercase)
                        Text(session.title.map { "\(subject.name) · \($0)" } ?? subject.name)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)
                        Text(when(session))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 12)
                    Button("Start") {
                        model.startFocus(session, now: now)
                        openWindow(id: FocusWindow.id)
                    }
                    .buttonStyle(.folioPrimary)
                    .help("Starts the timer and opens the files for this session")
                }
                if session.plan.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Decide what you'll do now, so it's ready when you sit down.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button("Plan Session…") { planning = session }
                            .buttonStyle(.folioLink)
                            .shotTarget("plan-session")
                    }
                    .padding(.leading, 54)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Your plan")
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.tertiaryText)
                            Spacer()
                            Button("Edit Plan…") { planning = session }
                                .buttonStyle(.folioLink)
                                .font(.system(size: 12))
                                .shotTarget("plan-session")
                        }
                        PlanChecklist(sessionID: session.id, limit: 5, allowsAdding: false, showsSuggestions: false, now: now)
                    }
                    .padding(.leading, 54)
                }
                let files = model.materials(for: session)
                if !files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            Button {
                                model.open(url)
                            } label: {
                                Label(url.lastPathComponent, systemImage: "doc")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.leading, 54)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(subject.color.opacity(0.14)))
            .sheet(item: $planning) { session in
                SessionSheet(session: session)
            }
        } else {
            // From Sunday midday this offers next week, since this one's nearly over.
            let week = model.weekToPlan(now: now)
            let isNextWeek = week > now
            let wasPlanned = !isNextWeek && model.sessions.contains { model.weekStart(containing: $0.start) == week }
            HStack(spacing: 16) {
                IconTile(systemName: "sparkles", foreground: Color.white, background: Theme.accent.opacity(0.55), size: 44, cornerRadius: 12, symbolSize: 19)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNextWeek ? "Next week isn't planned yet" : wasPlanned ? "Nothing more planned this week" : "Nothing planned yet")
                        .font(.system(size: 17, weight: .semibold))
                    Text(isNextWeek
                        ? "Folio can plan next week's study around school and your events, working back from what's due."
                        : "Folio can plan this week's study around school and your events, working back from what's due.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(isNextWeek ? "Plan Next Week" : "Plan My Week") {
                    withAnimation(Theme.motion()) { _ = model.planWeek(containing: week, now: now) }
                }
                .buttonStyle(.folioPrimary)
                .shotTarget("plan-week")
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .fill(LinearGradient(
                        colors: [Theme.accent.opacity(0.24), Theme.purple.opacity(0.14), Theme.cardBackground],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        }
    }

    /// "4:00 – 5:30 pm, in 20 minutes", or "Tomorrow, 4:00 – 5:30 pm".
    private func when(_ session: StudySession) -> String {
        let range = (session.start..<session.end).formatted(.interval.hour().minute())
        if model.calendar.isDate(session.start, inSameDayAs: now) {
            guard session.start > now else { return range }
            let minutes = Int((session.start.timeIntervalSince(now) / 60).rounded(.up))
            if minutes <= 1 { return String(localized: "\(range) · starting now") }
            if minutes < 60 { return String(localized: "\(range) · in \(minutes) minutes") }
            return "\(range) · \(session.start.formatted(.relative(presentation: .named)))"
        }
        return "\(session.start.formatted(.dateTime.weekday(.wide))), \(range)"
    }

}

/// Today's classes, from the school timetable and timetable calendars.
private struct ClassesToday: View {
    @Environment(AppModel.self) private var model
    let classes: [ClassSession]
    let now: Date

    private var hasTimetable: Bool {
        model.profile.timetable != nil || !model.timetableCalendarIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Classes today")
            if classes.isEmpty {
                HStack(spacing: 12) {
                    IconTile(
                        systemName: hasTimetable ? "cup.and.saucer" : "calendar.day.timeline.left",
                        foreground: Theme.accentText,
                        background: Theme.accent.opacity(0.14),
                        size: 30,
                        cornerRadius: 9,
                        symbolSize: 13
                    )
                    Text(hasTimetable
                         ? (model.calendar.isDateInWeekend(now) ? "No classes today. Enjoy the weekend." : "No classes today.")
                         : "Add your timetable to see your classes here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(classes.enumerated()), id: \.offset) { index, lesson in
                        let subject = model.subject(lesson.subjectID)
                        HStack(spacing: 10) {
                            SubjectDot(color: subject?.color ?? .gray)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(subject?.name ?? lesson.title)
                                    .font(.system(size: 13.5, weight: .medium))
                                Text((lesson.start..<lesson.end).formatted(.interval.hour().minute()))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if lesson.start <= now && lesson.end > now {
                                Text("Now")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.accentText)
                            }
                        }
                        .padding(.vertical, 9)
                        .opacity(lesson.end <= now ? 0.5 : 1)
                        .accessibilityElement(children: .combine)
                        if index < classes.count - 1 {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
        }
    }
}

/// How much is waiting in the Inbox, with a way there.
private struct InboxSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Inbox")
            VStack(alignment: .leading, spacing: 10) {
                if !model.needsReview.isEmpty {
                    Label(String(localized: "\(model.needsReview.count) files need a look"), systemImage: "questionmark.folder")
                }
                if !model.assessmentSuggestions.isEmpty {
                    Label(String(localized: "\(model.assessmentSuggestions.count) assessments found in your files"), systemImage: "calendar.badge.plus")
                }
                Button("Open Inbox") { model.destination = .inbox }
                    .buttonStyle(.folioGhost)
            }
            .font(.system(size: 13))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
        }
    }
}
