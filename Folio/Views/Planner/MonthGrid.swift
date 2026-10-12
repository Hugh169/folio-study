import SwiftUI
import FolioKit

/// A month at a glance: study sessions and due dates for each day.
/// Clicking a day opens it in Day view.
struct MonthGrid: View {
    @Environment(AppModel.self) private var model
    let month: Date
    let now: Date
    let onSelectDay: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 36)

            ForEach(weeks, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        MonthDayCell(
                            day: day,
                            isInMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                            isToday: calendar.isDate(day, inSameDayAs: now)
                        ) {
                            onSelectDay(day)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }

    private var calendar: Calendar { model.calendar }

    /// Short weekday names, starting on the calendar's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (symbols[first...] + symbols[..<first]).map { $0.uppercased() }
    }

    /// The whole weeks that cover the month.
    private var weeks: [[Date]] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        var start = model.weekStart(containing: interval.start)
        var result: [[Date]] = []
        while start < interval.end {
            result.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) })
            guard let next = calendar.date(byAdding: .day, value: 7, to: start) else { break }
            start = next
        }
        return result
    }
}

private struct MonthDayCell: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let isInMonth: Bool
    let isToday: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: isToday ? .semibold : .medium))
                    .foregroundStyle(isToday ? Color.white : Theme.primaryText)
                    .frame(width: 24, height: 24)
                    .background {
                        if isToday {
                            Circle().fill(Theme.accentFill)
                        }
                    }
                ForEach(assessments) { assessment in
                    Text(assessment.isSitting ? "\(String(localized: assessment.kind.title)): \(assessment.title)" : String(localized: "Due: \(assessment.title)"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.subject(assessment.subjectID)?.tintForeground ?? Theme.primaryText)
                        .lineLimit(1)
                }
                ForEach(sessions.prefix(3)) { session in
                    HStack(spacing: 5) {
                        SubjectDot(color: model.subject(session.subjectID)?.color ?? .gray)
                        Text(model.subject(session.subjectID)?.name ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                if sessions.count > 3 {
                    Text("+\(sessions.count - 3) more")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 96)
            .background(isToday ? Theme.accent.opacity(0.07) : (isHovered ? Theme.hover : Color.clear))
            .overlay(alignment: .top) {
                Theme.separator.frame(height: 1)
            }
            .overlay(alignment: .leading) {
                Theme.separator.frame(width: 1)
            }
            .opacity(isInMonth ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityHint("Opens this day")
    }

    private var sessions: [StudySession] {
        model.sessions
            .filter { model.calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
    }

    private var assessments: [Assessment] {
        model.assessments.filter { model.calendar.isDate($0.due, inSameDayAs: day) }
    }
}
