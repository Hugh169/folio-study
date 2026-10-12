import FolioKit
import SwiftUI

/// Enter a school timetable: one week or Week A and Week B, the bell times,
/// a subject for each period, and term dates if the student wants holidays
/// left free. Used by Settings › Planner and by setup.
struct TimetableEditor: View {
    enum Tab: CaseIterable, Identifiable {
        case classes, bells, terms

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .classes: "Classes"
            case .bells: "Bell Times"
            case .terms: "Term Dates"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let subjects: [Subject]
    /// `Calendar` weekdays with school, Monday first.
    let weekdays: [Int]
    let calendar: Calendar
    let onSave: (SchoolTimetable) -> Void
    var onRemove: (() -> Void)?

    @State private var timetable: SchoolTimetable
    @State private var tab: Tab = .classes
    @State private var shownWeek = 0

    init(timetable: SchoolTimetable, subjects: [Subject], weekdays: Set<Int>, calendar: Calendar, onSave: @escaping (SchoolTimetable) -> Void, onRemove: (() -> Void)? = nil) {
        _timetable = State(initialValue: timetable)
        self.subjects = subjects
        self.weekdays = (weekdays.isEmpty ? [2, 3, 4, 5, 6] : weekdays).sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
        self.calendar = calendar
        self.onSave = onSave
        self.onRemove = onRemove
    }

    /// A day in the school week the student means by "this week".
    private var thisWeek: Date {
        AppModel.schoolWeek(around: .now, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("School Timetable")
                    .font(.system(size: 17, weight: .semibold))
                Text("Folio shows your classes in the planner, plans study around school days, and notices files that arrive during a lesson.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                Picker("Repeats", selection: Binding(
                    get: { timetable.weekCount },
                    set: { count in
                        timetable.weekCount = count
                        shownWeek = min(shownWeek, count - 1)
                    }
                )) {
                    Text("Every week").tag(1)
                    Text("Week A and Week B").tag(2)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if timetable.weekCount == 2 {
                    HStack(spacing: 8) {
                        Text("The week of \(SchoolTimetable.monday(of: thisWeek, calendar: calendar).formatted(.dateTime.weekday(.wide).day().month(.wide))) is")
                            .foregroundStyle(Theme.secondaryText)
                        Picker("This week", selection: Binding(
                            get: { timetable.week(of: thisWeek, calendar: calendar) },
                            set: { timetable.setWeek($0, for: thisWeek, calendar: calendar) }
                        )) {
                            Text(AppModel.weekName(0)).tag(0)
                            Text(AppModel.weekName(1)).tag(1)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .font(.system(size: 13))
                }
            }

            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .classes: classes
                case .bells: bells
                case .terms: terms
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if let onRemove {
                    Button("Remove Timetable", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                    .buttonStyle(.folioGhost)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.folioGhost)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = timetable.tidied(keeping: Set(subjects.map(\.id)))
                    saved.periods.sort { $0.start < $1.start }
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(.folioPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(timetable.periods.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 780, height: 640)
        .background(Theme.windowBackground)
    }

    // MARK: Classes

    private var classes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if timetable.weekCount == 2 {
                HStack {
                    Picker("Week", selection: $shownWeek) {
                        Text(AppModel.weekName(0)).tag(0)
                        Text(AppModel.weekName(1)).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if shownWeek == 1 {
                        Button("Same as Week A") { timetable.copyWeekAToB() }
                    }
                }
            }
            if timetable.periods.isEmpty {
                ContentUnavailableView("No periods yet", systemImage: "bell", description: Text("Add your bell times first."))
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            ForEach(weekdays, id: \.self) { weekday in
                                Text(calendar.weekdaySymbols[weekday - 1])
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        ForEach(sortedPeriods) { period in
                            GridRow {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(period.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(Self.times(of: period, calendar: calendar))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.secondaryText)
                                        .minimumScaleFactor(0.8)
                                }
                                .lineLimit(1)
                                .frame(width: 124, alignment: .leading)
                                ForEach(weekdays, id: \.self) { weekday in
                                    LessonCell(
                                        subject: timetable.subject(week: shownWeek, weekday: weekday, period: period.id).flatMap { id in subjects.first { $0.id == id } },
                                        subjects: subjects,
                                        dayAndPeriod: "\(calendar.weekdaySymbols[weekday - 1]), \(period.name)"
                                    ) { subjectID in
                                        timetable.setSubject(subjectID, week: shownWeek, weekday: weekday, period: period.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var sortedPeriods: [SchoolTimetable.Period] {
        timetable.periods.sorted { $0.start < $1.start }
    }

    static func times(of period: SchoolTimetable.Period, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .minute, value: period.start, to: day),
              let end = calendar.date(byAdding: .minute, value: max(period.end, period.start), to: day)
        else { return "" }
        return (start..<end).formatted(.interval.hour().minute())
    }

    // MARK: Bell times

    private var bells: some View {
        Form {
            Section {
                ForEach($timetable.periods) { $period in
                    HStack(spacing: 10) {
                        TextField("Name", text: $period.name)
                            .labelsHidden()
                            .frame(width: 160)
                        MinutePicker(minutes: $period.start)
                        Text("to")
                            .foregroundStyle(.secondary)
                        MinutePicker(minutes: $period.end)
                        Spacer()
                        Button {
                            timetable.periods.removeAll { $0.id == period.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this period")
                        .accessibilityLabel("Remove \(period.name)")
                    }
                }
                Button("Add Period") { addPeriod() }
            } footer: {
                Text("Periods with classes. Leave out recess and lunch: Folio keeps the whole school day free, from the first bell to the last.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addPeriod() {
        let last = timetable.periods.max { $0.end < $1.end }
        let start = last?.end ?? 9 * 60
        let length = last.map { $0.end - $0.start } ?? 50
        timetable.periods.append(SchoolTimetable.Period(name: String(localized: "Period \(timetable.periods.count + 1)"), start: start, end: min(start + length, 24 * 60 - 1)))
    }

    // MARK: Term dates

    private var terms: some View {
        Form {
            Section {
                ForEach($timetable.terms) { $term in
                    HStack(spacing: 10) {
                        DatePicker("From", selection: $term.start, displayedComponents: .date)
                        DatePicker("to", selection: $term.end, in: term.start..., displayedComponents: .date)
                        Spacer()
                        Button {
                            timetable.terms.removeAll { $0.id == term.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this term")
                        .accessibilityLabel("Remove this term")
                    }
                }
                Button("Add Term") { addTerm() }
            } footer: {
                Text(timetable.terms.isEmpty
                    ? "Optional. Without term dates, classes show every week, holidays included."
                    : "Outside these dates there are no classes, so the planner can use school hours for study.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A ten-week term, after the last one or from this week.
    private func addTerm() {
        let after = timetable.terms.map(\.end).max().flatMap { calendar.date(byAdding: .day, value: 17, to: $0) }
        let start = SchoolTimetable.monday(of: after ?? thisWeek, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 7 * 10 - 3, to: start) ?? start
        timetable.terms.append(SchoolTimetable.Term(start: start, end: end))
    }
}

/// One period on one day: the subject taught, or a free period.
private struct LessonCell: View {
    let subject: Subject?
    let subjects: [Subject]
    let dayAndPeriod: String
    let choose: (Subject.ID?) -> Void

    var body: some View {
        Menu {
            Button("Free Period") { choose(nil) }
            Divider()
            ForEach(subjects) { subject in
                Button(subject.name) { choose(subject.id) }
            }
        } label: {
            Text(subject?.name ?? String(localized: "Free"))
                .font(.system(size: 11.5, weight: subject == nil ? .regular : .medium))
                .lineLimit(1)
                .foregroundStyle(subject.map(\.tintForeground) ?? Theme.tertiaryText)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background {
                    if let subject {
                        RoundedRectangle(cornerRadius: 7).fill(subject.color.opacity(0.24))
                    } else {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(dayAndPeriod)
        .accessibilityValue(subject.map { Text(verbatim: $0.name) } ?? Text("Free"))
    }
}
