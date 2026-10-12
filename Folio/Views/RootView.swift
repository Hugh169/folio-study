import AppKit
import FolioKit
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    /// Height of the window's toolbar band. Screen headers sit in this band so
    /// their titles line up with the toolbar buttons.
    @Entry var toolbarHeight: CGFloat = 52
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .setup:
                SetupView()
            case .ready:
                MainView()
            }
        }
        .background(Theme.windowBackground)
        .containerBackground(Theme.windowBackground, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // @AppStorage keeps to the model's settings, so a fresh start, the
        // self-test and render shots never change the student's own.
        .defaultAppStorage(model.settings)
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") { model.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
        // Files may have changed in Finder, or Apple Intelligence been switched on, while Folio was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refreshLibrary()
                await model.refreshAIStatus()
                await model.refreshNotificationStatus()
            }
        }
        // A curriculum pack someone shared, opened from Finder.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            switch url.pathExtension.lowercased() {
            case PackLibrary.fileExtension: model.openPack(at: url)
            case FolioBackup.fileExtension: model.openBackup(at: url)
            default: break
            }
        }
        .sheet(item: $model.openedPack) { pack in
            CoursePicker(pack: pack, isChosen: model.isTaking, toggle: { model.add($0, from: pack) }, canUntick: false)
        }
        // With the window closed Folio lives in the menu bar, without a Dock icon.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// The sidebar and the current screen.
private struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            HStack(spacing: 0) {
                HoverSidebar()
                ScreenView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.toolbarHeight, proxy.safeAreaInsets.top)
            // The sidebar and page headers run up under the transparent toolbar.
            .ignoresSafeArea(.container, edges: .top)
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.addFiles(urls)
            }
        }
        .sheet(isPresented: $model.isAddingSubject) {
            NewSubjectSheet()
        }
        // From Today, Progress or Sunday's reminder.
        .sheet(isPresented: $model.isShowingWeeklyReview) {
            WeeklyReviewSheet()
        }
    }
}

private struct ScreenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.destination {
        case .today:
            TodayView()
        case .inbox:
            InboxView()
        case .library:
            LibraryView()
        case .planner:
            PlannerView()
        case .study:
            StudyView()
        case .progress:
            ProgressScreen()
        case .subject(let id):
            if let subject = model.subject(id) {
                SubjectView(subject: subject)
            } else {
                LibraryView()
            }
        }
    }
}

/// A page: a header row in the toolbar band (title and optional subtitle),
/// a hairline, then the content.
struct Screen<Content: View>: View {
    @Environment(\.toolbarHeight) private var toolbarHeight
    let title: Text
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    init(title: LocalizedStringKey, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.subtitle = subtitle
        self.content = content()
    }

    /// A page named after something of the student's, such as a subject.
    init(verbatimTitle title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: toolbarHeight)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
