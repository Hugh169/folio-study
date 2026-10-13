import SwiftUI
import FolioKit

/// Asks before deleting everything Folio keeps, deletes it, then says what
/// happened and quits. Opened from Settings › AI & Privacy.
struct DeleteAllDataSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    enum Stage {
        case asking
        case deleting
        case done(DeletionReport)
    }

    @State private var stage: Stage
    @State private var removesReminders = true

    /// - Parameter report: Start at the end, for screenshots.
    init(report: DeletionReport? = nil) {
        _stage = State(initialValue: report.map(Stage.done) ?? .asking)
    }

    var body: some View {
        Group {
            switch stage {
            case .asking: asking
            case .deleting: deleting
            case .done(let report): done(report)
            }
        }
        .frame(width: 540)
        .background(Theme.windowBackground)
        .interactiveDismissDisabled(!isAsking)
    }

    private var isAsking: Bool {
        if case .asking = stage { true } else { false }
    }

    // MARK: Asking

    private var asking: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "trash", foreground: Theme.danger, background: Theme.danger.opacity(0.16), size: 44, cornerRadius: 12, symbolSize: 19)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete all of Folio's data?")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Folio forgets everything and quits, as if it had never been installed. This can't be undone.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                heading("Deleted")
                item("books.vertical", "Your subjects, timetable and settings")
                item("calendar", "Assessments, exams, marks and study plans")
                item("rectangle.on.rectangle.angled", "Study sessions, to-dos, flashcards and past-paper practice")
                item("arrow.uturn.backward", "What Folio learned, and its record of the files it filed, so they can't be put back")
                if model.hasClaudeKey {
                    item("key", "Your Claude API key, from your keychain")
                }
                item("bell", "Folio's notifications, and opening at login")
            }

            VStack(alignment: .leading, spacing: 9) {
                heading("Kept")
                item("folder", localized: String(localized: "Your \(model.libraryTitle) and every file in it, and any backups you saved"))
            }

            if model.usesReminders {
                Toggle("Also delete the reminders Folio added to Reminders", isOn: $removesReminders)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
            }

            HStack(spacing: 10) {
                if model.libraryURL != nil {
                    Button("Back Up First…") { model.backUp() }
                        .buttonStyle(.folioGhost)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.folioGhost)
                    .keyboardShortcut(.cancelAction)
                Button("Delete All Data") { delete() }
                    .buttonStyle(.folioDanger)
                    .shotTarget("confirm-delete-all")
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.tertiaryText)
    }

    private func item(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        item(symbol, Text(text))
    }

    /// An item whose words are already in the student's language.
    private func item(_ symbol: String, localized text: String) -> some View {
        item(symbol, Text(verbatim: text))
    }

    private func item(_ symbol: String, _ text: Text) -> some View {
        Label {
            text
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
        }
        .font(.system(size: 13))
    }

    // MARK: Deleting

    private var deleting: some View {
        VStack(spacing: 14) {
            ProgressView()
                .shotTarget("deleting-data")
            Text("Deleting Folio's data…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    private func delete() {
        stage = .deleting
        let removesReminders = removesReminders
        Task {
            let report = await model.deleteAllData(removingReminders: removesReminders)
            // Nothing can be saved any more, so close the windows that could change things.
            dismissWindow(id: "main")
            dismissWindow(id: FocusWindow.id)
            stage = .done(report)
        }
    }

    // MARK: Done

    private func done(_ report: DeletionReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "checkmark", foreground: Theme.success, background: Theme.success.opacity(0.16), size: 44, cornerRadius: 12, symbolSize: 19)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Folio's data is deleted")
                        .font(.system(size: 17, weight: .semibold))
                    Group {
                        Text("To remove Folio itself, delete it from your Applications folder. If you open it again instead, it starts from the beginning.")
                        if report.removedReminders > 0 {
                            Text(report.removedRemindersList
                                 ? String(localized: "Its \(report.removedReminders) reminders and the Folio list are gone from Reminders.")
                                 : String(localized: "Its \(report.removedReminders) reminders are gone from Reminders."))
                        }
                        Text("The permissions you gave Folio, such as for Calendar, stay in System Settings › Privacy & Security until you remove them.")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !report.problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.problems, id: \.self) { problem in
                        Label {
                            Text(verbatim: problem)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                        }
                        .font(.system(size: 12.5))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(Theme.warning.opacity(0.1)))
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Show in Finder") { model.quitAfterDeletingEverything(showingInFinder: true) }
                    .buttonStyle(.folioGhost)
                Button("Quit Folio") { model.quitAfterDeletingEverything(showingInFinder: false) }
                    .buttonStyle(.folioPrimary)
                    .keyboardShortcut(.defaultAction)
                    .shotTarget("quit-after-delete")
            }
            .padding(.top, 4)
        }
        .padding(24)
    }
}
