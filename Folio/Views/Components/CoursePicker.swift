import FolioKit
import SwiftUI

/// Every course in a curriculum pack, grouped and searchable, to tick the ones
/// the student takes. Used by setup and Settings › Subjects.
struct CoursePicker: View {
    @Environment(\.dismiss) private var dismiss
    let pack: CurriculumPack
    let isChosen: (PackSubject) -> Bool
    let toggle: (PackSubject) -> Void
    /// Off in Settings, where removing a subject is a separate step that keeps its folder.
    var canUntick = true
    @State private var search = ""

    private var groups: [(name: String, courses: [PackSubject])] {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        let matching = pack.subjects.filter { course in
            wanted.isEmpty || ([course.name, course.group ?? ""] + course.aliases + course.codes).contains { $0.localizedCaseInsensitiveContains(wanted) }
        }
        var order: [String] = []
        for course in matching where !order.contains(course.group ?? "") {
            order.append(course.group ?? "")
        }
        return order.map { group in (name: group, courses: matching.filter { ($0.group ?? "") == group }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(pack.name) courses")
                    .font(.system(size: 17, weight: .semibold))
                Text("Tick the courses you take.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            TextField("Search", text: $search, prompt: Text("Search courses"))
                .textFieldStyle(.roundedBorder)

            List {
                ForEach(groups, id: \.name) { group in
                    Section(group.name.isEmpty ? String(localized: "Other") : group.name) {
                        ForEach(group.courses) { course in
                            Toggle(isOn: Binding(get: { isChosen(course) }, set: { _ in toggle(course) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(course.name)
                                    if let detail = detail(for: course) {
                                        Text(detail)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!canUntick && isChosen(course))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 360)
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.folioPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .background(Theme.windowBackground)
    }

    /// Other names and codes, such as "3U Maths · 0580".
    private func detail(for course: PackSubject) -> String? {
        let parts = Array(course.aliases.prefix(2)) + course.codes.prefix(2).map { $0.hasSuffix("*") ? String($0.dropLast()) : $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
