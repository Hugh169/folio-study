import AppKit
import FolioKit
import SwiftUI

/// The menu bar window: what Folio is watching, what it filed recently with
/// Undo, and what needs a look. Folio keeps running here when its window is closed.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if model.phase == .ready {
                if let focus = model.focus {
                    divider
                    FocusLine(focus: focus) { openTimer() }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                if !glance.isEmpty {
                    divider
                    Button {
                        show(.today)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(glance, id: \.text) { line in
                                HStack(spacing: 10) {
                                    Image(systemName: line.systemImage)
                                        .frame(width: 16)
                                        .foregroundStyle(line.color)
                                    Text(line.text)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Today")
                }

                if !model.backgroundSorting.isEmpty {
                    divider
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.backgroundSorting.count == 1
                            ? "Sorting \(model.backgroundSorting.values.first ?? String(localized: "a file"))…"
                            : "Sorting \(model.backgroundSorting.count) files…")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                if !model.needsReview.isEmpty {
                    divider
                    Button {
                        show(.inbox)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                            Text("\(model.needsReview.count) files need a look")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.tertiaryText)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                divider
                if model.recentlySorted.isEmpty {
                    Text("Files Folio sorts appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionTitle("Recently sorted", leadingInset: 0)
                            .padding(.bottom, 4)
                        ForEach(model.recentlySorted.prefix(4)) { file in
                            MenuBarFileRow(file: file)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }

            divider
            VStack(spacing: 0) {
                menuButton("Open Folio") { show(nil) }
                if model.phase == .ready && model.watchedFolders.contains(where: \.isOn) {
                    menuButton(model.isWatchingPaused ? "Resume Watching" : "Pause Watching") {
                        model.setWatchingPaused(!model.isWatchingPaused)
                    }
                }
                SettingsLink {
                    menuLabel("Settings…")
                }
                .buttonStyle(.plain)
                menuButton("Quit Folio") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 320)
        .background(Theme.windowBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(systemName: "tray.and.arrow.down", foreground: Theme.accent, background: Theme.accent.opacity(0.16), size: 30, cornerRadius: 8, symbolSize: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("Folio")
                    .font(.system(size: 14, weight: .semibold))
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    struct GlanceLine {
        var systemImage: String
        var color: Color
        var text: String
    }

    /// Today in brief: the next class, the next study session and what's due next.
    private var glance: [GlanceLine] {
        let now = Date.now
        var lines: [GlanceLine] = []
        if let lesson = model.classes(on: now).first(where: { $0.end > now }), let subject = model.subject(lesson.subjectID) {
            let time = lesson.start.formatted(.dateTime.hour().minute())
            lines.append(GlanceLine(systemImage: "clock", color: subject.color, text: lesson.start <= now ? String(localized: "\(subject.name) now") : String(localized: "\(subject.name) at \(time)")))
        }
        if let session = model.nextSession(after: now), model.calendar.isDate(session.start, inSameDayAs: now), let subject = model.subject(session.subjectID) {
            let time = session.start.formatted(.dateTime.hour().minute())
            let name = session.title.map { "\(subject.name) · \($0)" } ?? subject.name
            lines.append(GlanceLine(systemImage: "book", color: subject.color, text: session.start <= now ? String(localized: "Studying \(name) now") : String(localized: "Study \(name) at \(time)")))
        }
        if let next = model.upcomingAssessments(within: 14, now: now).first, let subject = model.subject(next.subjectID) {
            lines.append(GlanceLine(systemImage: next.kind.systemImage, color: subject.color, text: "\(next.title) · \(model.countdown(to: next.due, now: now))"))
        }
        let cards = model.dueCards(at: now).count
        if cards > 0 {
            lines.append(GlanceLine(systemImage: "rectangle.on.rectangle.angled", color: Theme.success, text: String(localized: "\(cards) cards to review")))
        }
        return lines
    }

    private var status: String {
        guard model.phase == .ready else { return String(localized: "Open Folio to set it up") }
        let watching = model.watchedFolders.filter(\.isOn).map(\.displayName)
        if watching.isEmpty { return String(localized: "Not watching any folders") }
        if model.isWatchingPaused { return String(localized: "Paused") }
        return String(localized: "Watching \(watching.formatted(.list(type: .and)))")
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
    }

    private func menuButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { menuLabel(title) }
            .buttonStyle(.plain)
    }

    private func menuLabel(_ title: LocalizedStringKey) -> some View {
        MenuRowLabel(title: title)
    }

    private func openTimer() {
        openWindow(id: FocusWindow.id)
        NSApp.activate()
    }

    /// Brings the main window back, showing `destination` if given.
    private func show(_ destination: Destination?) {
        if let destination { model.destination = destination }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MenuRowLabel: View {
    let title: LocalizedStringKey
    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .onHover { isHovered = $0 }
    }
}

private struct MenuBarFileRow: View {
    @Environment(AppModel.self) private var model
    let file: SortedFile

    var body: some View {
        HStack(spacing: 10) {
            SubjectDot(color: model.subject(file.subjectID)?.color ?? .gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.location(of: file.subjectID, folder: file.folder))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Undo") { model.undo(file) }
                .buttonStyle(.folioLink)
                .help("Put this file back where it was")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show in Finder") { model.showInFinder(file.url) }
        }
    }
}

/// The study timer in brief: what's being studied, the time left, and its controls.
private struct FocusLine: View {
    @Environment(AppModel.self) private var model
    let focus: FocusSession
    let openTimer: () -> Void

    var body: some View {
        let subject = model.subject(focus.subjectID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .foregroundStyle(subject?.color ?? Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(focus.title.map { "\(subject?.name ?? "") · \($0)" } ?? subject?.name ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(focus.isOver ? String(localized: "Time's up") : focus.isPaused ? String(localized: "Paused") : String(localized: "\(Int((focus.remaining(at: context.date) / 60).rounded(.up))) minutes left"))
                            .font(.system(size: 12))
                            .foregroundStyle(focus.isOver ? Theme.warning : Theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if !focus.isOver {
                    Button(focus.isPaused ? "Resume" : "Pause") {
                        focus.isPaused ? model.resumeFocus() : model.pauseFocus()
                    }
                    .buttonStyle(FilledButtonStyle(kind: .ghost, height: 26))
                }
                Button(focus.isOver ? "Say How It Went" : "Show Timer", action: openTimer)
                    .buttonStyle(FilledButtonStyle(kind: focus.isOver ? .primary : .ghost, height: 26))
            }
        }
    }
}
