import SwiftUI
import FolioKit

/// The planner's time grid: one column per day, 8 am to 8 pm, with school as a
/// quiet grey block, classes from the school timetable on it, and study
/// sessions in their subject's colour.
struct CalendarGrid: View {
    static let hourHeight: CGFloat = 44
    static let firstHour = 8
    static let lastHour = 20
    static let gutterWidth: CGFloat = 52

    @Environment(AppModel.self) private var model
    let days: [Date]
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutterWidth)
                ForEach(days, id: \.self) { day in
                    DayHeader(date: day, isToday: model.calendar.isDate(day, inSameDayAs: now), showsFullName: days.count == 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 60)

            if hasAllDayItems {
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: Self.gutterWidth)
                    ForEach(days, id: \.self) { day in
                        AllDayItems(day: day)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.bottom, 6)
            }

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                HourLabels()
                    .frame(width: Self.gutterWidth)
                ForEach(days, id: \.self) { day in
                    DayColumn(day: day, isToday: model.calendar.isDate(day, inSameDayAs: now))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 5)
        }
    }
}

extension CalendarGrid {
    private var hasAllDayItems: Bool {
        days.contains { day in
            model.calendarEvents.contains { $0.isAllDay && AllDayItems.covers($0, day: day, calendar: model.calendar) }
                || model.assessments.contains { !$0.isDone && !$0.isSitting && model.calendar.isDate($0.due, inSameDayAs: day) }
        }
    }
}

/// All-day events and what's due, under a day's header.
private struct AllDayItems: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(dueToday) { assessment in
                chip(text: String(localized: "Due: \(assessment.title)"), color: model.subject(assessment.subjectID)?.color ?? Theme.accent, isDeadline: true)
                    .help("\(assessment.title), due \(assessment.due.formatted(.dateTime.hour().minute()))")
            }
            ForEach(events) { event in
                chip(text: event.title, color: Color(hex: event.colorHex), isDeadline: false)
                    .help(event.title)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Tasks due today. Exams and tests show in the grid at their time instead.
    private var dueToday: [Assessment] {
        model.assessments.filter { !$0.isDone && !$0.isSitting && model.calendar.isDate($0.due, inSameDayAs: day) }
    }

    private var events: [BusyBlock] {
        model.calendarEvents.filter { $0.isAllDay && Self.covers($0, day: day, calendar: model.calendar) }
    }

    static func covers(_ event: BusyBlock, day: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: day)
        return event.start <= start.addingTimeInterval(12 * 60 * 60) && event.end > start
    }

    private func chip(text: String, color: Color, isDeadline: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11, weight: isDeadline ? .semibold : .regular))
        .foregroundStyle(isDeadline ? Theme.primaryText : Theme.secondaryText)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(isDeadline ? 0.1 : 0.05)))
    }
}

private struct DayHeader: View {
    let date: Date
    let isToday: Bool
    let showsFullName: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(date.formatted(.dateTime.weekday(showsFullName ? .wide : .abbreviated)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isToday ? Theme.accent : Theme.secondaryText)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 19, weight: isToday ? .semibold : .medium))
                .foregroundStyle(isToday ? Color.white : Theme.primaryText)
                .frame(width: 28, height: 28)
                .background {
                    if isToday {
                        Circle().fill(Theme.accentFill)
                    }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isToday ? .isSelected : [])
    }
}

private struct HourLabels: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ForEach(CalendarGrid.firstHour..<CalendarGrid.lastHour, id: \.self) { hour in
                Text(label(for: hour))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: CalendarGrid.hourHeight, alignment: .top)
                    .offset(y: -5)
            }
        }
        .accessibilityHidden(true)
    }

    private func label(for hour: Int) -> String {
        let date = model.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }
}

private struct DayColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let day: Date
    let isToday: Bool
    @State private var editing: StudySession?
    @State private var creating: NewSessionRequest?
    /// Where the pointer last was, for "New Session Here…". Not observed, so
    /// moving the pointer doesn't redraw the column.
    @State private var pointer = PointerPosition()

    private var perMinute: CGFloat { CalendarGrid.hourHeight / 60 }

    var body: some View {
        ZStack(alignment: .top) {
            HourLines()

            if let school = schoolBlock {
                SchoolBlock(showsLabel: model.profile.timetable == nil)
                    .frame(height: school.height)
                    .padding(.horizontal, 4)
                    .offset(y: school.top)
            }

            ForEach(Array(classes.enumerated()), id: \.offset) { _, lesson in
                if let subject = model.subject(lesson.subjectID) {
                    let frame = blockFrame(from: lesson.start, to: lesson.end)
                    ClassBlock(subject: subject, lesson: lesson)
                        .frame(height: frame.height)
                        .padding(.horizontal, 4)
                        .offset(y: frame.top)
                }
            }

            GeometryReader { proxy in
                ForEach(EventLayout.columns(for: events)) { placed in
                    let frame = blockFrame(from: placed.event.start, to: placed.event.end)
                    let width = (proxy.size.width - 8) / CGFloat(placed.columnCount)
                    EventBlock(event: placed.event)
                        .frame(width: max(width - 2, 10), height: frame.height)
                        .offset(x: 4 + width * CGFloat(placed.column), y: frame.top)
                }
            }

            ForEach(sittings) { assessment in
                if let subject = model.subject(assessment.subjectID), let sitting = assessment.sitting {
                    let frame = blockFrame(from: sitting.start, to: sitting.end)
                    SittingBlock(subject: subject, assessment: assessment)
                        .frame(height: frame.height)
                        .padding(.horizontal, 4)
                        .offset(y: frame.top)
                }
            }

            ForEach(sessions) { session in
                if let subject = model.subject(session.subjectID) {
                    let frame = blockFrame(from: session.start, to: session.end)
                    // A button, so VoiceOver and a click both open it to change.
                    Button {
                        editing = session
                    } label: {
                        SessionBlock(subject: subject, session: session)
                    }
                    .buttonStyle(.plain)
                    .frame(height: frame.height)
                    .padding(.horizontal, 4)
                    .offset(y: frame.top)
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                    .shotTarget("session-\(session.id)")
                    .contextMenu {
                        Button("Edit Session…") { editing = session }
                        Divider()
                        if !session.isRecorded {
                            Button("Start Studying") {
                                model.startFocus(session)
                                openWindow(id: FocusWindow.id)
                            }
                            .disabled(model.focus != nil)
                            Button("Mark as Done") { model.record(session, as: .done) }
                            Button("Mark as Skipped") { model.record(session, as: .skipped) }
                            Divider()
                        }
                        Button("Remove Session") {
                            withAnimation(Theme.motion()) { model.removeSession(session) }
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(CalendarGrid.lastHour - CalendarGrid.firstHour) * CalendarGrid.hourHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase { pointer.y = point.y }
        }
        .contextMenu {
            Button("New Session Here…") {
                creating = NewSessionRequest(start: startTime(at: pointer.y))
            }
        }
        .sheet(item: $editing) { session in
            SessionSheet(session: session)
        }
        .sheet(item: $creating) { request in
            SessionSheet(session: nil, start: request.start, subjectID: request.subjectID)
        }
        .background(isToday ? Theme.accent.opacity(0.07) : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.separator)
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }

    private var sessions: [StudySession] {
        model.sessions.filter { model.calendar.isDate($0.start, inSameDayAs: day) }
    }

    /// Exams and tests on this day.
    private var sittings: [Assessment] {
        model.assessments.filter { $0.isSitting && model.calendar.isDate($0.due, inSameDayAs: day) }
    }

    /// Classes from the school timetable on this day.
    private var classes: [ClassSession] {
        model.timetableClasses(on: day)
    }

    /// Timed events from the student's calendars on this day.
    private var events: [BusyBlock] {
        model.calendarEvents.filter { !$0.isAllDay && model.calendar.isDate($0.start, inSameDayAs: day) }
    }

    private var schoolBlock: (top: CGFloat, height: CGFloat)? {
        guard let school = model.schoolHours(on: day) else { return nil }
        let top = CGFloat(school.start - CalendarGrid.firstHour * 60) * perMinute
        return (top, CGFloat(school.end - school.start) * perMinute)
    }

    /// The quarter hour at a height in the column, leaving room for an hour before the grid ends.
    private func startTime(at y: CGFloat) -> Date {
        let lastStart = (CalendarGrid.lastHour - CalendarGrid.firstHour - 1) * 60
        let minutes = min(max(Int(y / perMinute) / 15 * 15, 0), lastStart) + CalendarGrid.firstHour * 60
        let start = model.calendar.startOfDay(for: day)
        return model.calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
    }

    /// Where a block sits in the grid, with a 1 pt gap above and below.
    private func blockFrame(from start: Date, to end: Date) -> (top: CGFloat, height: CGFloat) {
        let startMinute = minutesIntoGrid(start)
        let endMinute = minutesIntoGrid(end)
        return (CGFloat(startMinute) * perMinute + 1, max(CGFloat(endMinute - startMinute) * perMinute - 2, 16))
    }

    private func minutesIntoGrid(_ date: Date) -> Int {
        let parts = model.calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) - CalendarGrid.firstHour * 60
        return min(max(minutes, 0), (CalendarGrid.lastHour - CalendarGrid.firstHour) * 60)
    }
}

/// The pointer's last height in a day column.
private final class PointerPosition {
    var y: CGFloat = 0
}

private struct HourLines: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(CalendarGrid.firstHour..<CalendarGrid.lastHour, id: \.self) { _ in
                Color.clear.frame(height: CalendarGrid.hourHeight - 1)
                Theme.gridLine.frame(height: 1)
            }
        }
    }
}

private struct SchoolBlock: View {
    /// Off when the timetable's classes are drawn on top.
    var showsLabel = true

    var body: some View {
        Text(showsLabel ? "School" : "")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(Color.white.opacity(0.055)))
            .accessibilityHidden(!showsLabel)
    }
}

/// A class from the school timetable: quiet, with a strip in its subject's colour.
private struct ClassBlock: View {
    let subject: Subject
    let lesson: ClassSession

    private var timeRange: String {
        (lesson.start..<max(lesson.start, lesson.end)).formatted(.interval.hour().minute())
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(subject.color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(subject.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                Text(timeRange)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile - 2))
        .help("\(lesson.title)\n\(timeRange)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lesson.title), \(timeRange)")
    }
}

/// An event from the student's calendar: quiet, with a strip in its calendar's colour.
private struct EventBlock: View {
    let event: BusyBlock

    private var timeRange: String {
        (event.start..<max(event.start, event.end)).formatted(.interval.hour().minute())
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(hex: event.colorHex))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                Text(timeRange)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile - 2))
        .help([event.title, timeRange, event.location].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }
}

/// Puts overlapping events side by side.
enum EventLayout {
    struct Placed: Identifiable {
        let event: BusyBlock
        let column: Int
        let columnCount: Int
        var id: String { event.id }
    }

    static func columns(for events: [BusyBlock]) -> [Placed] {
        var placed: [Placed] = []
        var cluster: [(event: BusyBlock, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            let count = max(columnEnds.count, 1)
            placed += cluster.map { Placed(event: $0.event, column: $0.column, columnCount: count) }
            cluster = []
            columnEnds = []
        }

        for event in events.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if event.start >= clusterEnd { closeCluster() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = event.end
                cluster.append((event, free))
            } else {
                columnEnds.append(event.end)
                cluster.append((event, columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, event.end)
        }
        closeCluster()
        return placed
    }
}

private struct SessionBlock: View {
    let subject: Subject
    let session: StudySession

    private var timeRange: String {
        (session.start..<session.end).formatted(.interval.hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if session.isRecorded {
                    Image(systemName: session.outcome == .skipped ? "minus.circle" : session.outcome == .partly ? "circle.lefthalf.filled" : "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(subject.name)
                    .strikethrough(session.outcome == .skipped)
            }
            .font(.system(size: 12, weight: .semibold))
            if let title = session.title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(timeRange)
                    if !session.plan.isEmpty {
                        Label {
                            Text(verbatim: "\(session.plan.filter(\.isDone).count)/\(session.plan.count)")
                        } icon: {
                            Image(systemName: "checklist")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                Text(timeRange)
            }
            .font(.system(size: 11))
        }
        .lineLimit(1)
        .foregroundStyle(subject.tintForeground)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(subject.color.opacity(session.outcome == .skipped ? 0.1 : 0.24)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        .opacity(session.outcome == .skipped ? 0.7 : 1)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the session to change it and its plan")
    }

    /// The details, the plan, and whether Plan My Week will keep it.
    private var helpText: String {
        var lines = [[subject.name, session.title, timeRange].compactMap { $0 }.joined(separator: ", ")]
        lines += session.plan.map { ($0.isDone ? "✓ " : "• ") + $0.title }
        if let note = session.note { lines.append(note) }
        if session.isOwn && !session.isRecorded { lines.append(String(localized: "Yours: Plan My Week leaves it where it is.")) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var base = if let title = session.title {
            String(localized: "\(subject.name) study session for \(title), \(timeRange)")
        } else {
            String(localized: "\(subject.name) study session, \(timeRange)")
        }
        if !session.plan.isEmpty {
            base += ", " + String(localized: "plan: \(session.plan.filter(\.isDone).count) of \(session.plan.count) done", comment: "How much of a study session's plan is ticked off, read by VoiceOver")
        }
        switch session.outcome {
        case .done: return String(localized: "\(base), done")
        case .partly: return String(localized: "\(base), partly done")
        case .skipped: return String(localized: "\(base), skipped")
        case nil: return base
        }
    }
}

/// An exam or test, at its time, outlined in its subject's colour.
private struct SittingBlock: View {
    let subject: Subject
    let assessment: Assessment

    private var timeRange: String {
        guard let sitting = assessment.sitting else { return "" }
        return (sitting.start..<sitting.end).formatted(.interval.hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(assessment.title, systemImage: assessment.kind.systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text([timeRange, assessment.room].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
        }
        .lineLimit(1)
        .foregroundStyle(Theme.primaryText)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(subject.color.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile).strokeBorder(subject.color, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        .help("\(assessment.title), \(timeRange)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(String(localized: assessment.kind.title)): \(assessment.title), \(timeRange)")
    }
}
