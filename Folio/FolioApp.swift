import AppIntents
import SwiftUI

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model: AppModel
        #if DEBUG
        if let folder = RenderShots.folder {
            model = AppModel.sample()
            Task { RenderShots.run(in: folder) }
        } else if let folder = SelfTest.folder {
            model = SelfTest.makeModel(in: folder)
            Task { await SelfTest.run(model, in: folder) }
        } else if FreshStart.isOn {
            model = FreshStart.makeModel()
        } else {
            model = AppModel.live()
        }
        #else
        model = AppModel.live()
        #endif
        _model = State(initialValue: model)
        // Shortcuts actions sort through the same model as the window.
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        // One main window. Closing it leaves Folio running in the menu bar.
        Window("Folio", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1240, height: 820)
        .defaultLaunchBehavior(isSelfTest ? .suppressed : .automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            FolioCommands(model: model)
        }

        // The study timer, small and in front of other windows.
        Window("Study Timer", id: FocusWindow.id) {
            FocusWindow()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra(isInserted: .constant(!isSelfTest && !model.hasDeletedEverything)) {
            MenuBarView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        } label: {
            MenuBarLabel(focus: model.focus)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }

    /// A self-test or render run, which shows no window or menu bar item.
    private var isSelfTest: Bool {
        #if DEBUG
        SelfTest.folder != nil || RenderShots.folder != nil
        #else
        false
        #endif
    }
}

/// Folio's menu bar item: its icon, and the time left while the study timer runs.
private struct MenuBarLabel: View {
    let focus: FocusSession?

    var body: some View {
        if let focus, !focus.isOver {
            if let end = focus.endsAt {
                Label {
                    Text(timerInterval: .now...max(end, .now), countsDown: true)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "timer")
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label("Paused", systemImage: "pause.circle")
                    .labelStyle(.titleAndIcon)
            }
        } else if focus?.isOver == true {
            Label("Time's up", systemImage: "timer")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "tray.and.arrow.down")
                .accessibilityLabel("Folio")
        }
    }
}

/// Keeps Folio running in the menu bar when its window closes, so watched
/// folders are still sorted.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DeletedEverything.cleanUpAtQuit?()
    }
}

/// Menu items: Add Files (⌘O), Show School Folder (or Uni Folder), Back Up and
/// Restore, and ⌘1–6 to switch between the main screens.
private struct FolioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { model.isImporting = true }
                .keyboardShortcut("o")
                .disabled(model.phase != .ready)
            Button(model.profile.level == .university ? "Show Uni Folder in Finder" : "Show School Folder in Finder") { model.open(model.libraryURL) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.libraryURL == nil)
            Divider()
            Button("Back Up Folio…") { model.backUp() }
                .disabled(model.phase != .ready || model.libraryURL == nil)
            Button("Restore from Backup…") { model.chooseAndRestoreBackup() }
                .disabled(model.live == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Today") { model.destination = .today }
                .keyboardShortcut("1")
            Button("Inbox") { model.destination = .inbox }
                .keyboardShortcut("2")
            Button("Planner") { model.destination = .planner }
                .keyboardShortcut("3")
            Button("Study") { model.destination = .study }
                .keyboardShortcut("4")
            Button("Library") { model.destination = .library }
                .keyboardShortcut("5")
            Button("Progress") { model.destination = .progress }
                .keyboardShortcut("6")
            Divider()
        }
    }
}
