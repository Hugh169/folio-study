import SwiftUI
import FolioKit

/// Adds a whole exam timetable at once, such as trial or final exams: one
/// row per exam, with its subject, start, length and room.
struct ExamsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        var id = UUID()
        var subjectID: Subject.ID?
        var start: Date
        var lengthMinutes = 120
        var room = ""
    }

    @State private var name = ""
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Exams")
                    .font(.system(size: 17, weight: .semibold))
                Text("Folio plans revision in the weeks before each one, and nothing else while it's on.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack(spacing: 10) {
                Text("Called")
                TextField("Called", text: $name, prompt: Text("e.g. Trial exams"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 260)
            }
            .help("Each exam is named after its subject and this, such as “Biology Trial exams”.")

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($rows) { $row in
                        HStack(spacing: 10) {
                            Picker("Subject", selection: $row.subjectID) {
                                Text("Choose…").tag(Subject.ID?.none)
                                ForEach(model.subjects) { subject in
                                    Text(subject.name).tag(Optional(subject.id))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(width: 170, alignment: .leading)
                            DatePicker("Starts", selection: $row.start, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                            Stepper(value: $row.lengthMinutes, in: 10...360, step: 10) {
                                Text("\(row.lengthMinutes) min")
                                    .monospacedDigit()
                                    .frame(width: 58, alignment: .trailing)
                            }
                            TextField("Room", text: $row.room, prompt: Text("Room"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityLabel("Remove Exam")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 320)

            Button("Add Another Exam", action: addRow)
                .buttonStyle(.folioLink)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(readyRows.isEmpty ? String(localized: "Add Exams") : String(localized: "Add \(readyRows.count) Exams"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(readyRows.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear {
            if rows.isEmpty {
                for _ in 0..<3 { addRow() }
            }
        }
    }

    private var readyRows: [Row] {
        rows.filter { $0.subjectID.flatMap(model.subject) != nil }
    }

    /// A new row a day after the last one, at 9 am.
    private func addRow() {
        let base = rows.last?.start ?? model.calendar.date(byAdding: .day, value: 14, to: .now) ?? .now
        let day = rows.isEmpty ? base : model.calendar.date(byAdding: .day, value: 1, to: base) ?? base
        let start = model.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        rows.append(Row(start: start, lengthMinutes: rows.last?.lengthMinutes ?? 120))
    }

    private func save() {
        let period = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let exams = readyRows.compactMap { row -> Assessment? in
            guard let subject = row.subjectID.flatMap(model.subject) else { return nil }
            let title = period.isEmpty ? String(localized: "\(subject.name) exam") : "\(subject.name) \(period)"
            return Assessment(
                title: title,
                subjectID: subject.id,
                kind: .exam,
                due: row.start,
                lengthMinutes: row.lengthMinutes,
                room: row.room.trimmingCharacters(in: .whitespaces).isEmpty ? nil : row.room
            )
        }
        withAnimation(Theme.motion()) { model.addAssessments(exams) }
        dismiss()
    }
}
