import SwiftUI
import FolioKit

/// The week at a glance: what's due, study planned and classes, day by day.
/// A day opens in the planner.
struct WeekStrip: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let start = model.weekStart(containing: now)
        // Every day as tall as the busiest one.
        HStack(spacing: 10) {
            ForEach(0..<7, id: \.self) { offset in
                if let day = model.calendar.date(byAdding: .day, value: offset, to: start) {
                    DayCell(day: day, now: now)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DayCell: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let now: Date
    @State private var isHovered = false

    var body: some View {
        let calendar = model.calendar
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isPast = day < calendar.startOfDay(for: now)
        let due = model.assessments.filter { !$0.isDone && calendar.isDate($0.due, inSameDayAs: day) }
        let sessions = model.sessions.filter { calendar.isDate($0.start, inSameDayAs: day) }

        Button {
            model.requestedPlannerDate = day
            model.plannerMode = .day
            model.destination = .planner
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 11.5, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(isToday ? Theme.accentText : Theme.secondaryText)
                    Spacer(minLength: 0)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? Color.white : Theme.primaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(isToday ? Theme.accent : Color.clear))
                }

                ForEach(due.prefix(2)) { assessment in
                    HStack(spacing: 5) {
                        Image(systemName: assessment.kind.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(model.subject(assessment.subjectID)?.color ?? Theme.secondaryText)
                        Text(assessment.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                }
                if due.count > 2 {
                    Text("\(due.count - 2) more due")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }

                Spacer(minLength: 0)

                if !sessions.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(sessions.prefix(6)) { session in
                            Capsule()
                                .fill(model.subject(session.subjectID)?.color ?? Theme.secondaryText)
                                .frame(height: 4)
                        }
                    }
                }
                Text(summary(sessions: sessions.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(isHovered ? Theme.cardHover : Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isToday ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5))
            .opacity(isPast ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open this day in the Planner")
        .accessibilityElement(children: .combine)
    }

    /// "2 sessions · 3 classes", or "Nothing planned" when there's nothing.
    private func summary(sessions: Int) -> String {
        let classes = model.classes(on: day).count
        let events = model.calendarEvents.filter { !$0.isAllDay && model.calendar.isDate($0.start, inSameDayAs: day) }.count
        var parts: [String] = []
        if sessions > 0 { parts.append(String(localized: "\(sessions) sessions")) }
        if classes > 0 { parts.append(String(localized: "\(classes) classes")) }
        if events > 0 { parts.append(String(localized: "\(events) events")) }
        return parts.isEmpty ? String(localized: "Nothing planned") : parts.joined(separator: " · ")
    }
}

/// A number worth knowing at a glance, such as the hours of study planned this week.
struct StatTile: View {
    let systemImage: String
    let colour: Color
    let value: String
    let label: LocalizedStringKey
    let detail: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconTile(systemName: systemImage, foreground: colour, background: colour.opacity(0.16), size: 28, cornerRadius: 8, symbolSize: 12.5)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .opacity(isHovered ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(isHovered ? Theme.cardHover : Theme.cardBackground))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// This week in numbers: what's due, study planned, files sorted and the Inbox.
struct TodayStats: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let due = model.upcomingAssessments(within: 7, now: now)
        let minutes = model.studyMinutes(inWeekOf: now)
        let cards = model.dueCards(at: now).count
        let waiting = model.needsReview.count + model.assessmentSuggestions.count

        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatTile(
                    systemImage: "calendar.badge.clock",
                    colour: Theme.warning,
                    value: due.count.formatted(),
                    label: "Due in 7 days",
                    detail: due.first.map { String(localized: "Next: \($0.title)") } ?? String(localized: "Nothing due")
                ) {
                    model.plannerMode = .assessments
                    model.destination = .planner
                }
                StatTile(
                    systemImage: "clock",
                    colour: Theme.accent,
                    value: (Double(minutes.recorded) / 60).formatted(.number.precision(.fractionLength(0...1))),
                    label: "Hours studied",
                    detail: minutes.planned == 0
                        ? String(localized: "This week is open")
                        : String(localized: "Of \(StudyFormat.duration(minutes: minutes.planned)) planned")
                ) {
                    model.destination = .study
                }
            }
            GridRow {
                StatTile(
                    systemImage: "rectangle.on.rectangle.angled",
                    colour: Theme.success,
                    value: cards.formatted(),
                    label: "Cards to review",
                    detail: model.flashcards.isEmpty ? String(localized: "Make some in Study") : String(localized: "\(model.flashcards.count) cards in all")
                ) {
                    model.destination = .study
                }
                StatTile(
                    systemImage: "tray",
                    colour: Theme.purple,
                    value: waiting.formatted(),
                    label: "In the Inbox",
                    detail: waiting == 0 ? String(localized: "All caught up") : String(localized: "Waiting for you")
                ) {
                    model.destination = .inbox
                }
            }
        }
    }
}

/// The first things to set up, ticked off as they're done. It goes once
/// everything is done, or when the student hides it.
struct SetupChecklist: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hidesSetupChecklist") private var isHidden = false
    @State private var isEditingTimetable = false
    @State private var isAddingAssessment = false

    private struct Step: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let isDone: Bool
        let button: LocalizedStringKey
        let action: () -> Void
    }

    private var steps: [Step] {
        let downloads = model.watchedFolders.first(where: \.isDownloads)
        return [
            Step(id: "timetable", title: "Add your timetable", detail: "See your classes here and keep school time free.",
                 isDone: model.profile.timetable != nil || !model.timetableCalendarIDs.isEmpty, button: "Add…") {
                isEditingTimetable = true
            },
            Step(id: "calendar", title: "Connect Apple Calendar", detail: "Study is planned around your events.",
                 isDone: model.isCalendarConnected, button: "Connect…") {
                Task { await model.connectCalendar() }
            },
            Step(id: "assessment", title: "Add an assessment or exam", detail: "Folio plans study back from when it's due.",
                 isDone: !model.assessments.isEmpty, button: "Add…") {
                isAddingAssessment = true
            },
            Step(id: "downloads", title: "Sort your downloads", detail: "Schoolwork you download is filed as it arrives.",
                 isDone: downloads?.isOn == true, button: "Turn On") {
                if let downloads { model.setWatching(downloads, on: true) }
            },
        ]
    }

    var body: some View {
        let steps = steps
        let done = steps.filter(\.isDone).count
        if !isHidden && done < steps.count {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle("Get set up")
                    Spacer()
                    Button("Hide") {
                        withAnimation(Theme.motion()) { isHidden = true }
                    }
                    .buttonStyle(.folioLink)
                    .help("Hide this list. Everything here is also in Settings.")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 5)
                            .overlay(alignment: .leading) {
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(Theme.success)
                                        .frame(width: proxy.size.width * Double(done) / Double(steps.count))
                                }
                            }
                        Text("\(done) of \(steps.count)")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(step.isDone ? Theme.success : Theme.tertiaryText)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(step.isDone ? Theme.secondaryText : Theme.primaryText)
                                if !step.isDone {
                                    Text(step.detail)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 6)
                            if !step.isDone {
                                Button(step.button, action: step.action)
                                    .buttonStyle(.folioLink)
                                    .disabled(model.live == nil)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(step.isDone ? Text("Done") : Text(verbatim: ""))
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
            .sheet(isPresented: $isEditingTimetable) {
                TimetableEditor(
                    timetable: model.profile.timetable ?? model.newTimetable(),
                    subjects: model.subjects,
                    weekdays: model.profile.studyPreferences.schoolHours?.weekdays ?? SchoolHours().weekdays,
                    calendar: model.calendar,
                    onSave: { model.profile.timetable = $0 },
                    onRemove: nil
                )
            }
            .sheet(isPresented: $isAddingAssessment) {
                AssessmentSheet(assessment: nil)
            }
        }
    }
}

/// Every subject in its colour, with what's next for it. A subject opens its page.
struct SubjectGrid: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(verbatim: model.subjectsTitle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(model.subjects) { subject in
                    SubjectTile(subject: subject, now: now)
                }
            }
        }
    }
}

private struct SubjectTile: View {
    @Environment(AppModel.self) private var model
    let subject: Subject
    let now: Date
    @State private var isHovered = false

    var body: some View {
        Button {
            model.destination = .subject(subject.id)
        } label: {
            HStack(spacing: 12) {
                Capsule()
                    .fill(subject.color)
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(subject.color.opacity(isHovered ? 0.2 : 0.11)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }

    /// "Essay · in 3 days", else a teacher, else the file count.
    private var detail: String {
        if let next = model.assessments(of: subject.id).first(where: { !$0.isDone && $0.due >= model.calendar.startOfDay(for: now) }) {
            return "\(next.title) · \(model.countdown(to: next.due, now: now))"
        }
        let count = model.fileCount(of: subject.id)
        let files = count == 0 ? String(localized: "No files yet") : fileCountText(count)
        return ([files] + subject.teachers.prefix(1)).joined(separator: " · ")
    }
}
