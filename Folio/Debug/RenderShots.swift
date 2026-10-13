#if DEBUG
import AppKit
import FolioKit
import SwiftUI

/// Draws Folio's screens with made-up data into PNGs, without showing a window:
///
///     Folio.app/Contents/MacOS/Folio -FolioRenderShots <folder> [-FolioShots library,planner] [-AppleLanguages "(fr)"]
///
/// `<folder>` must be inside Folio's container. Running inside the app means
/// the renders use its translations and icon. `-FolioShotsHighContrast YES`
/// draws them as Increase Contrast would. Debug builds only.
///
/// SwiftUI only builds its accessibility tree for a real assistive client such
/// as VoiceOver, so labels can't be checked from here.
enum RenderShots {
    static var folder: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-FolioRenderShots"), index + 1 < arguments.count else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    /// Only these shots, from `-FolioShots a,b`, or all of them.
    private static var only: Set<String>? {
        UserDefaults.standard.string(forKey: "FolioShots").map { Set($0.split(separator: ",").map(String.init)) }
    }

    struct Shot {
        let name: String
        var width: CGFloat = 1240
        var height: CGFloat = 820
        var toolbar = true
        /// Something done to the window before it's drawn, such as a click,
        /// returning a line for shots.txt about what happened.
        var act: ((NSWindow) -> String)? = nil
        let view: () -> AnyView
    }

    static func run(in folder: URL) {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rendered = shots().filter { only?.contains($0.name) ?? true }.map { render($0, into: folder) }
        try? rendered.joined(separator: "\n").write(to: folder.appending(path: "shots.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    // MARK: Drawing

    private final class OffscreenWindow: NSWindow {
        /// Set while a shot clicks, so the click isn't spent making the window key.
        var actsAsKey = false
        override var isKeyWindow: Bool { actsAsKey || super.isKeyWindow }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Draws one shot and returns its file name.
    private static func render(_ shot: Shot, into folder: URL) -> String {
        let root = shot.view()
            .defaultAppStorage(AppModel.sampleSettings)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        let hosting = NSHostingView(rootView: root)
        if shot.toolbar { hosting.sceneBridgingOptions = [.toolbars] }
        let origin = NSPoint(x: -30000, y: -30000)
        let window = OffscreenWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: shot.width, height: shot.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: UserDefaults.standard.bool(forKey: "FolioShotsHighContrast") ? .accessibilityHighContrastDarkAqua : .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(Theme.windowBackground)
        window.contentView = hosting
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        defer { window.orderOut(nil) }

        var note = ""
        if let act = shot.act {
            note = "  " + act(window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }

        let frameView = window.contentView!.superview!
        if let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(shot.name).png"))
        }
        return "\(shot.name).png" + note
    }

    // MARK: Acting on a shot

    /// Every view inside `view`, deepest last.
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private static func firstList(in window: NSWindow) -> NSTableView? {
        window.contentView.flatMap { descendants(of: $0).lazy.compactMap { $0 as? NSTableView }.first }
    }

    /// Which row of the window's list is selected, such as for a file chosen
    /// before the sheet opened.
    static func listSelection(in window: NSWindow) -> String {
        guard let table = firstList(in: window) else { return "no list" }
        return "selected row \(table.selectedRow) of \(table.numberOfRows)"
    }

    /// Clicks the middle of the list's first row as a mouse would, then says
    /// which row is selected.
    ///
    /// The press goes straight to the view under the pointer: sent through
    /// the window, it's spent trying to bring Folio forward. A view that
    /// follows the pointer takes the release from the queue itself; anything
    /// else is handed it after, since the app's event loop isn't running
    /// while shots are drawn.
    static func clickFirstRow(in window: NSWindow) -> String {
        guard let table = firstList(in: window), table.numberOfRows > 0 else { return "no list to click" }
        let row = table.rect(ofRow: 0)
        guard click(at: table.convert(NSPoint(x: row.midX, y: row.midY), to: nil), in: window, direct: true) else { return "nothing to click" }
        return "clicked the first row, " + listSelection(in: window)
    }

    /// Scrolls the first scrolling area to its end, such as a Settings pane.
    static func scrollToEnd(in window: NSWindow) -> String {
        func first(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height { return scroll }
            return view.subviews.lazy.compactMap(first(in:)).first
        }
        guard let content = window.contentView, let scroll = first(in: content), let document = scroll.documentView else { return "nothing to scroll" }
        let end = document.isFlipped ? max(0, document.frame.height - scroll.contentSize.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return "scrolled to the end"
    }

    /// Clicks the middle of a view marked with `shotTarget(name)`. A view
    /// moved with `offset` reports where it was before the move, so `lowered`
    /// adds that back.
    static func click(target name: String, in window: NSWindow, lowered: CGFloat = 0) -> String {
        guard let frame = ShotTargets.frames[name], let content = window.contentView else { return "no \(name) on screen" }
        let y = content.isFlipped ? frame.midY + lowered : content.bounds.height - frame.midY - lowered
        return click(at: content.convert(NSPoint(x: frame.midX, y: y), to: nil), in: window) ? "clicked \(name)" : "couldn't click \(name)"
    }

    /// Numbers each click's press and release alike, as the system does.
    private static var clickNumber = 0

    /// Presses and lets go at `point`, in the window's coordinates.
    ///
    /// SwiftUI's own controls only see a click that goes through the window,
    /// so it goes there first, with the window acting as key so the press
    /// isn't spent bringing it forward. A list follows the pointer until the
    /// button comes up, so the release waits in the queue for it; anything
    /// else is handed the release after, since the app's event loop isn't
    /// running while shots are drawn. With `direct`, the press goes straight
    /// to the view under the pointer instead, which AppKit lists need.
    private static func click(at point: NSPoint, in window: NSWindow, direct: Bool = false) -> Bool {
        guard let frame = window.contentView?.superview else { return false }
        clickNumber += 1
        let pressedAt = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: type == .leftMouseDown ? pressedAt : pressedAt + 0.08,
                windowNumber: window.windowNumber, context: nil, eventNumber: clickNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )
        }
        guard let target = frame.hitTest(point), let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) else { return false }
        (window as? OffscreenWindow)?.actsAsKey = true
        defer { (window as? OffscreenWindow)?.actsAsKey = false }
        NSApp.postEvent(up, atStart: true)
        if direct {
            target.mouseDown(with: down)
        } else {
            window.sendEvent(down)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return true
    }

    /// Every card answered today, so none are due until tomorrow or later.
    private static func reviewedEverything(_ model: AppModel) {
        let tomorrow = model.calendar.date(byAdding: .day, value: 1, to: model.calendar.startOfDay(for: .now))!
        model.flashcards = model.flashcards.map { card in
            var card = card
            card.due = max(card.due, tomorrow)
            card.reviewedAt = .now
            return card
        }
    }

    /// Holds a shot's model, made when the shot is drawn, so its action can look at it after.
    private final class ShotModel {
        var model: AppModel?
    }

    // MARK: Screens

    /// The main window's layout, without the toolbar plumbing of `RootView`.
    private struct ShotRoot: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    HoverSidebar(startsExpanded: false)
                    screen.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .environment(\.toolbarHeight, proxy.safeAreaInsets.top)
                .ignoresSafeArea(.container, edges: .top)
            }
            .background(Theme.windowBackground)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }

        @ViewBuilder private var screen: some View {
            switch model.destination {
            case .today: TodayView()
            case .inbox: InboxView()
            case .library: LibraryView()
            case .planner: PlannerView()
            case .study: StudyView()
            case .progress: ProgressScreen()
            case .subject(let id): SubjectView(subject: model.subject(id)!)
            }
        }
    }

    /// The Library with a search typed in, in the main window's layout.
    private struct ShotRootLibrary: View {
        let query: String
        let hits: [SearchHit]

        var body: some View {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    HoverSidebar(startsExpanded: false)
                    LibraryView(query: query, hits: hits).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .environment(\.toolbarHeight, proxy.safeAreaInsets.top)
                .ignoresSafeArea(.container, edges: .top)
            }
            .background(Theme.windowBackground)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }

    private static func sample(_ configure: (AppModel) -> Void) -> AppModel {
        let model = AppModel.sample()
        configure(model)
        return model
    }

    /// Setup partway through, with the HSC chosen.
    private static func setup(_ step: SetupModel.Step, pack id: String = "au-nsw-hsc") -> SetupModel {
        let setup = SetupModel()
        setup.showsWelcome = false
        setup.studentName = "Sam"
        setup.choose(PackLibrary.pack(id)!)
        setup.reached = .done
        setup.step = step
        return setup
    }

    /// A Week A/B timetable for the sample subjects, with this week as Week A.
    private static func timetable(_ model: AppModel) -> SchoolTimetable {
        var timetable = model.newTimetable()
        timetable.weekCount = 2
        let subjects = model.subjects
        for (index, period) in timetable.periods.enumerated() {
            for weekday in 2...6 {
                timetable.setSubject(subjects[(index + weekday) % subjects.count].id, week: 0, weekday: weekday, period: period.id)
                timetable.setSubject(subjects[(index + weekday + 2) % subjects.count].id, week: 1, weekday: weekday, period: period.id)
            }
        }
        return timetable
    }

    /// A week of the student's own events, with study planned around them.
    private static func busyWeek(_ model: AppModel) {
        let week = model.weekStart(containing: .now)
        func day(_ offset: Int) -> Date { model.calendar.date(byAdding: .day, value: offset, to: week)! }
        func event(_ id: String, _ title: String, _ offset: Int, _ start: Double, _ end: Double, _ colour: UInt32) -> BusyBlock {
            BusyBlock(id: id, title: title, start: day(offset).addingTimeInterval(start * 3600), end: day(offset).addingTimeInterval(end * 3600), calendarID: "personal", colorHex: colour)
        }
        model.isCalendarConnected = true
        model.calendarEvents = [
            event("1", "Netball training", 0, 16, 17.5, 0x30D158),
            event("2", "Tutoring", 1, 17, 18, 0xBF5AF2),
            event("3", "Part-time job", 2, 16.5, 20, 0xFF9F0A),
            BusyBlock(id: "4", title: "School excursion", start: day(3), end: day(4), isAllDay: true, calendarID: "personal", colorHex: 0x0A84FF),
        ]
        _ = model.planWeek(containing: week, now: week)
    }

    private static func calendars(_ model: AppModel) {
        model.isCalendarConnected = true
        model.calendarList = [
            CalendarInfo(id: "personal", title: "Personal", account: "iCloud", colorHex: 0x30D158, isUsuallyIgnored: false),
            CalendarInfo(id: "work", title: "Work", account: "iCloud", colorHex: 0xFF9F0A, isUsuallyIgnored: false),
            CalendarInfo(id: "birthdays", title: "Birthdays", account: "Other", colorHex: 0x8E8E93, isUsuallyIgnored: true),
        ]
        model.plannedCalendarIDs = ["personal", "work"]
        model.usesReminders = true
    }

    /// A task sheet found in a file, and a marked copy of work handed back.
    private static func suggestions(_ model: AppModel) -> [AssessmentSuggestion] {
        let s = model.subjects
        let due = model.calendar.date(byAdding: .day, value: 18, to: model.calendar.startOfDay(for: .now))!.addingTimeInterval(15 * 3600)
        let found = AssessmentReader.Found(title: "Task 2: Depth Study – Investigating Enzymes", kind: .task, due: due, weighting: 30, totalMarks: 40)
        let marked = model.assessments.first { $0.status == .marked }
        return [
            AssessmentSuggestion(offer: .new(found), subjectID: s[3].id, fileName: "Chemistry Task 2 notification.pdf"),
            AssessmentSuggestion(offer: .link(marked?.id ?? UUID(), .returned), subjectID: s[4].id, fileName: "Source analysis – marked.pdf", mark: Assessment.Mark(score: 21, outOf: 25, grade: "A")),
        ]
    }

    /// A new student's Folio: eleven HSC subjects, more than most students
    /// take, to test the layout, and nothing planned, due or sorted yet.
    private static func newStudent(_ model: AppModel) {
        let pack = PackLibrary.pack("au-nsw-hsc")!
        let courses = ["english-advanced", "maths-advanced", "maths-ext1", "biology", "chemistry", "physics", "modern-history", "business-studies", "economics", "legal-studies", "visual-arts"]
        let colours: [UInt32] = [0xFF453A, 0xAC8E68, 0x66D4CF, 0xFFD60A, 0xFF6482, 0x40C8E0, 0x0A84FF, 0xFF9F0A, 0xBF5AF2, 0x30D158, 0x5E5CE6]
        model.profile.subjects = zip(courses, colours).compactMap { id, colour in pack.course(id).map { pack.subject(for: $0, colorHex: colour) } }
        model.profile.studentName = "Sam"
        model.profile.timetable = nil
        model.folders = [:]
        model.assessments = []
        model.sessions = []
        model.recentlySorted = []
        model.sorting = []
        model.needsReview = []
        model.assessmentSuggestions = []
    }

    /// To-dos in a few subjects, and plans in the next sessions: the first
    /// part done in one, Folio's suggestions taken in another.
    private static func planning(_ model: AppModel) {
        let s = model.subjects
        let (english, physics, chemistry) = (s[1], s[2], s[3])
        let report = model.assessments.first { $0.title == "Projectile motion report" }
        let essay = model.assessments.first { $0.title == "Poetry analysis essay" }
        let today = model.calendar.startOfDay(for: .now)
        func ago(_ days: Int) -> Date { model.calendar.date(byAdding: .day, value: -days, to: today)! }
        model.todos = [
            Todo(subjectID: physics.id, title: "Redo question 4 of the practical", assessmentID: report?.id, minutes: 20, createdAt: ago(4)),
            Todo(subjectID: physics.id, title: "Copy up Tuesday's notes on circular motion", createdAt: ago(2)),
            Todo(subjectID: english.id, title: "Find three quotes about memory", assessmentID: essay?.id, minutes: 15, createdAt: ago(3)),
            Todo(subjectID: chemistry.id, title: "Make a summary sheet for organic chemistry", minutes: 45, createdAt: ago(1)),
            Todo(subjectID: english.id, title: "Ask Ms Nguyen about the word limit", isDone: true, createdAt: ago(6), doneAt: ago(1)),
        ]
        var upcoming = model.sessions.indices.filter { model.sessions[$0].end > .now }.sorted { model.sessions[$0].start < model.sessions[$1].start }
        if upcoming.isEmpty, let tomorrow = model.calendar.date(byAdding: DateComponents(day: 1, hour: 16), to: today) {
            // Late on the sample week's last day every session is over, so
            // add one tomorrow: there's always a next session to plan.
            model.sessions.append(StudySession(subjectID: physics.id, start: tomorrow, end: tomorrow.addingTimeInterval(3600), assessmentID: report?.id, title: report?.title))
            upcoming = [model.sessions.count - 1]
        }
        if let first = upcoming.first {
            let subject = model.sessions[first].subjectID
            let todo = model.todos.first { $0.subjectID == subject && !$0.isDone }
            model.sessions[first].plan = [
                PlanStep(title: String(localized: "Read over last lesson's notes"), isDone: true),
                todo.map(\.step) ?? PlanStep(title: String(localized: "Questions 1 to 6 of the worksheet")),
                PlanStep(title: String(localized: "Write a summary of the method")),
            ]
            model.sessions[first].isOwn = true
        }
        if upcoming.count > 2 {
            let index = upcoming[2]
            model.sessions[index].plan.add(model.suggestions(for: model.sessions[index]))
        }
    }

    /// Ten weeks of marks across the subjects, four weeks of recorded study
    /// (little of it Physics), three things due in one week next month, and
    /// a subject from last term.
    private static func progressing(_ model: AppModel) {
        let s = model.subjects
        let (maths, english, physics, chemistry, history) = (s[0], s[1], s[2], s[3], s[4])
        let today = model.calendar.startOfDay(for: .now)
        func day(_ offset: Int, _ hour: Int = 9) -> Date { model.calendar.date(byAdding: DateComponents(day: offset, hour: hour), to: today)! }
        func marked(_ title: String, _ subject: Subject, _ score: Double, _ outOf: Double, weighting: Double, due: Int, back: Int) -> Assessment {
            Assessment(
                title: title, subjectID: subject.id, due: day(due), weighting: weighting, totalMarks: outOf, status: .marked,
                mark: Assessment.Mark(score: score, outOf: outOf), markedAt: day(back, 15)
            )
        }
        model.assessments += [
            marked("Algebra test", maths, 21, 30, weighting: 15, due: -63, back: -55),
            marked("Functions assignment", maths, 44, 50, weighting: 20, due: -28, back: -18),
            marked("Calculus quiz", maths, 16, 20, weighting: 10, due: -9, back: -2),
            marked("Creative writing", english, 18, 25, weighting: 20, due: -45, back: -37),
            marked("Novel study essay", english, 34, 40, weighting: 25, due: -16, back: -4),
            marked("Motion practical", physics, 31, 40, weighting: 20, due: -30, back: -21),
            marked("Stoichiometry test", chemistry, 27, 40, weighting: 25, due: -36, back: -26),
        ]
        // Three things due in one week, a month out: a crowded week.
        let busy = model.calendar.date(byAdding: .weekOfYear, value: 4, to: model.weekStart(containing: .now))!
        func inBusyWeek(_ offset: Int) -> Date { model.calendar.date(byAdding: DateComponents(day: offset, hour: 9), to: busy)! }
        model.assessments += [
            Assessment(title: "Depth Study", subjectID: english.id, due: inBusyWeek(0), weighting: 30),
            Assessment(title: "Mechanics test", subjectID: physics.id, kind: .test, due: inBusyWeek(2), weighting: 15),
            Assessment(title: "Cold War essay", subjectID: history.id, due: inBusyWeek(3), weighting: 25),
        ]
        model.assessments.sort { $0.due < $1.due }
        // Study recorded in the three weeks before this one: mostly English and Maths.
        for week in 1...3 {
            for (index, subject) in [english, maths, english, chemistry, maths, history].enumerated() {
                let start = day(-7 * week + index, 16)
                model.sessions.append(StudySession(
                    subjectID: subject.id, start: start, end: start.addingTimeInterval(3600),
                    doneMinutes: index == 4 ? 30 : 55, outcome: index == 4 ? .partly : .done
                ))
            }
        }
        // Last term's Geography.
        var geography = Subject(name: "Geography", colorHex: 0x30D158, term: "Term 2", isArchived: true)
        geography.folderName = "Geography"
        model.profile.subjects.append(geography)
        model.assessments.append(marked("Fieldwork report", geography, 38, 50, weighting: 30, due: -100, back: -90))
        model.sessions.append(StudySession(subjectID: geography.id, start: day(-104, 16), end: day(-104, 17), doneMinutes: 60, outcome: .done))
    }

    /// Flashcards, finished sessions, a practised paper and Physics past papers,
    /// as a student a few weeks into using the study tools would have.
    private static func studying(_ model: AppModel) {
        let s = model.subjects
        let (maths, english, physics, chemistry, history) = (s[0], s[1], s[2], s[3], s[4])
        let today = model.calendar.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { model.calendar.date(byAdding: .day, value: offset, to: today)! }
        func card(_ subject: Subject, _ question: String, _ answer: String, box: Int, due: Int, source: String, quote: String? = nil) -> Flashcard {
            Flashcard(subjectID: subject.id, question: question, answer: answer, sourceName: source, quote: quote, origin: .onDevice, box: box, due: day(due), createdAt: day(-12), reviewCount: box, missCount: 0)
        }
        model.flashcards = [
            card(physics, "What is Lenz's law?", "The induced current flows in a direction that opposes the change in flux that produced it.", box: 1, due: 0, source: "Electromagnetism notes.docx",
                 quote: "Lenz's law: the induced current flows in a direction that creates a magnetic field opposing the change in flux that produced it."),
            card(physics, "What does a step-up transformer do?", "It increases the voltage: the secondary coil has more turns than the primary.", box: 2, due: 0, source: "Electromagnetism notes.docx"),
            card(physics, "Why are transformer cores laminated?", "To reduce the energy lost to eddy currents in the core.", box: 3, due: 2, source: "Electromagnetism notes.docx"),
            card(physics, "What is magnetic flux?", "The magnetic field strength times the area perpendicular to it: Φ = B⊥A.", box: 4, due: 6, source: "Electromagnetism notes.docx"),
            card(physics, "What is the unit of magnetic flux?", "The weber (Wb).", box: 5, due: 20, source: "Electromagnetism notes.docx"),
            card(chemistry, "What is a Brønsted–Lowry acid?", "A proton (H⁺) donor.", box: 1, due: 0, source: "Acid base reactions.pdf"),
            card(chemistry, "What is a buffer?", "A solution that resists changes in pH when small amounts of acid or base are added.", box: 2, due: 0, source: "Acid base reactions.pdf"),
            card(chemistry, "Which indicator suits a weak acid and a strong base?", "Phenolphthalein, which changes colour at about pH 8.2 to 10.", box: 2, due: 1, source: "Acid base reactions.pdf"),
            card(english, "What does Macbeth's 'vaulting ambition' show?", "Ambition without moral limits leads to his destruction.", box: 1, due: 0, source: "Macbeth themes.docx"),
            card(english, "Who says 'Out, damned spot!'?", "Lady Macbeth, sleepwalking and trying to wash imaginary blood from her hands.", box: 3, due: 4, source: "Macbeth themes.docx"),
            card(history, "What did the Enabling Act allow?", "Hitler's cabinet could make laws without the Reichstag for four years.", box: 2, due: 0, source: "Nazi Germany 1933-34.docx"),
            card(history, "When did Hitler become Führer?", "August 1934, after Hindenburg died.", box: 4, due: 9, source: "Nazi Germany 1933-34.docx"),
            card(maths, "What is the chain rule?", "If y = f(g(x)), then dy/dx = f′(g(x)) × g′(x).", box: 2, due: 3, source: "Differentiation rules.pdf"),
        ]
        // The first sessions of the week, finished with the timer.
        let week = model.weekStart(containing: .now)
        let finished: [(Int, StudySession.Outcome, Int, String?)] = [
            (0, .done, 85, "Finished the integration practice set"),
            (1, .partly, 40, "Drafted the first two paragraphs"),
            (2, .done, 60, nil),
            (3, .skipped, 0, "Netball ran late"),
        ]
        for (index, outcome, minutes, note) in finished where index < model.sessions.count {
            if model.sessions[index].start < .now || model.sessions[index].start < week.addingTimeInterval(86_400 * 2) {
                model.sessions[index].outcome = outcome
                model.sessions[index].doneMinutes = minutes
                model.sessions[index].note = note
            }
        }
        model.practiceAttempts = [
            PracticeAttempt(subjectID: physics.id, paperName: "2021-hsc-physics.pdf", date: day(-5), minutes: 175, mark: Assessment.Mark(score: 74, outOf: 100), note: "Rushed the last extended response"),
        ]
        let folder = URL(filePath: "/Users/student/Documents/School/Physics/Past Papers", directoryHint: .isDirectory)
        model.libraryFiles = ["2023-hsc-physics.pdf", "2023-hsc-physics-mg.pdf", "2021-hsc-physics.pdf", "2021-hsc-physics-mg.pdf", "2019 trial physics.pdf"].enumerated().map { index, name in
            SortedFile(name: name, subjectID: physics.id, folder: "Past Papers", sortedAt: day(-index), url: folder.appending(path: name))
        }
    }

    /// The study timer partway through a planned session.
    private static func focusing(_ model: AppModel, over: Bool = false, plan: [PlanStep]? = nil) {
        let s = model.subjects
        let started = Date.now.addingTimeInterval(-21 * 60)
        var focus = FocusSession(
            subjectID: s[2].id, title: "Projectile motion report: Draft", minutes: 60, startedAt: started, runningSince: started,
            files: [URL(filePath: "/tmp/Projectile Motion Worksheet.pdf"), URL(filePath: "/tmp/Prac report - draft.docx")]
        )
        if let plan {
            let report = model.assessments.first { $0.title == "Projectile motion report" }
            let session = StudySession(
                subjectID: s[2].id, start: started, end: started.addingTimeInterval(3600), assessmentID: report?.id,
                title: focus.title, plan: plan, isOwn: true
            )
            model.sessions.append(session)
            focus.sessionID = session.id
            focus.assessmentID = report?.id
        }
        if over {
            focus.banked = 58 * 60
            focus.runningSince = nil
            focus.isOver = true
            let paper = PastPapers.papers(from: [
                PastPapers.File(name: "2023-hsc-physics.pdf", url: URL(filePath: "/tmp/2023-hsc-physics.pdf"), year: 2023, exam: "HSC"),
                PastPapers.File(name: "2023-hsc-physics-mg.pdf", url: URL(filePath: "/tmp/2023-hsc-physics-mg.pdf")),
            ]).first
            focus.paper = paper
            focus.title = paper?.title
            focus.files = [URL(filePath: "/tmp/2023-hsc-physics.pdf")]
        }
        model.focus = focus
    }

    private static func shots() -> [Shot] {
        [
            Shot(name: "today") {
                AnyView(ShotRoot().environment(sample { model in
                    model.destination = .today
                    model.profile.timetable = timetable(model)
                    model.assessmentSuggestions = suggestions(model)
                }))
            },
            Shot(name: "today-empty", height: 1180) {
                AnyView(ShotRoot().environment(sample { model in
                    newStudent(model)
                    model.destination = .today
                }))
            },
            Shot(name: "inbox-empty", height: 1000) {
                AnyView(ShotRoot().environment(sample { model in
                    newStudent(model)
                    model.destination = .inbox
                }))
            },
            Shot(name: "inbox-quiet") {
                AnyView(ShotRoot().environment(sample { model in
                    model.destination = .inbox
                    model.sorting = []
                    model.needsReview = []
                    var downloads = WatchedFolder.downloads
                    downloads.isOn = true
                    model.watchedFolders = [downloads]
                }))
            },
            Shot(name: "assessments") {
                AnyView(ShotRoot().environment(sample { model in
                    model.destination = .planner
                    model.plannerMode = .assessments
                }))
            },
            Shot(name: "inbox-assessments") {
                AnyView(ShotRoot().environment(sample { model in
                    model.destination = .inbox
                    model.sorting = []
                    model.needsReview = []
                    model.assessmentSuggestions = suggestions(model)
                }))
            },
            Shot(name: "library") { AnyView(ShotRoot().environment(sample { $0.destination = .library })) },
            Shot(name: "inbox") {
                AnyView(ShotRoot().environment(sample { model in
                    model.destination = .inbox
                    let s = model.subjects
                    model.sorting = [
                        SortingItem(name: "2023-hsc-modern-history-exam.pdf", detail: "Past Papers · HSC 2023 · 12 pages", status: .filed(subjectID: s[4].id, folder: "Past Papers")),
                        SortingItem(name: "IMG_7003.jpg", detail: "Reading the text in the image…", status: .reading),
                        SortingItem(name: "Untitled 2.pdf", detail: "Worksheets · 2 pages", status: .needsLook),
                        SortingItem(name: "Cafe roster week 32.pdf", detail: "Doesn't look like schoolwork, so it's still in Downloads", status: .leftAlone),
                    ]
                    model.needsReview = [
                        ReviewItem(
                            name: "Untitled 2.pdf",
                            question: "Could be Chemistry or Physics. Which one should it go to?",
                            suggestions: [s[3].id, s[2].id],
                            folder: nil,
                            reasons: ["Found “titration”, “burette”", "On-device AI chose Physics"],
                            url: URL(filePath: "/tmp/Untitled 2.pdf")
                        ),
                    ]
                }))
            },
            Shot(name: "subject") { AnyView(ShotRoot().environment(sample { $0.destination = .subject($0.subjects[2].id) })) },
            Shot(name: "planner") {
                AnyView(ShotRoot().environment(sample { model in
                    model.destination = .planner
                    busyWeek(model)
                }))
            },
            Shot(name: "planner-timetable") {
                AnyView(ShotRoot().environment(sample { model in
                    model.destination = .planner
                    model.profile.timetable = timetable(model)
                    _ = model.planWeek(containing: model.weekStart(containing: .now), now: model.weekStart(containing: .now))
                }))
            },
            Shot(name: "welcome", toolbar: false) { AnyView(SetupView().environment(sample { $0.phase = .setup })) },
            Shot(name: "setup-1-school", toolbar: false) { AnyView(SetupView(setup: setup(.school)).environment(sample { $0.phase = .setup })) },
            Shot(name: "setup-2-subjects", toolbar: false) { AnyView(SetupView(setup: setup(.subjects)).environment(sample { $0.phase = .setup })) },
            Shot(name: "setup-3-folders", toolbar: false) { AnyView(SetupView(setup: setup(.folders)).environment(sample { $0.phase = .setup })) },
            Shot(name: "setup-4-week", toolbar: false) { AnyView(SetupView(setup: setup(.week)).environment(sample { $0.phase = .setup })) },
            Shot(name: "setup-5-done", toolbar: false) { AnyView(SetupView(setup: setup(.done)).environment(sample { $0.phase = .setup })) },
            Shot(name: "course-picker", width: 480, height: 560, toolbar: false) {
                let setup = setup(.subjects)
                return AnyView(CoursePicker(pack: setup.pack!, isChosen: setup.isChosen, toggle: { setup.toggle($0) }).environment(sample { _ in }))
            },
            Shot(name: "timetable-editor", width: 780, height: 640, toolbar: false) {
                let model = sample { _ in }
                return AnyView(TimetableEditor(timetable: timetable(model), subjects: model.subjects, weekdays: [2, 3, 4, 5, 6], calendar: model.calendar, onSave: { _ in }, onRemove: {}).environment(model))
            },
            Shot(name: "settings-subjects", width: 700, height: 600, toolbar: false) { AnyView(SettingsView(pane: .subjects).environment(sample { _ in })) },
            Shot(name: "settings-folders", width: 700, height: 640, toolbar: false) {
                AnyView(SettingsView(pane: .folders).environment(sample { $0.libraryURL = URL(filePath: "/Users/student/Documents/School") }))
            },
            Shot(name: "settings-sorting", width: 700, height: 600, toolbar: false) { AnyView(SettingsView(pane: .sorting).environment(sample { _ in })) },
            Shot(name: "settings-planner", width: 700, height: 860, toolbar: false) {
                AnyView(SettingsView(pane: .planner).environment(sample { model in
                    calendars(model)
                    model.profile.timetable = timetable(model)
                }))
            },
            Shot(name: "settings-ai", width: 700, height: 800, toolbar: false) {
                AnyView(SettingsView(pane: .ai).environment(sample { model in
                    model.learnedExampleCount = 23
                    model.libraryURL = URL(filePath: "/Users/student/Documents/School")
                }))
            },
            // The end of AI & Privacy, with Delete All Data, and a Claude key saved.
            Shot(name: "settings-ai-end", width: 700, height: 800, toolbar: false, act: scrollToEnd) {
                AnyView(SettingsView(pane: .ai).environment(sample { model in
                    model.learnedExampleCount = 23
                    model.libraryURL = URL(filePath: "/Users/student/Documents/School")
                    model.hasClaudeKey = true
                    model.claudeStatus = .ready
                    model.claudeUsage = ClaudeUsageLedger.Usage(requests: 37, inputTokens: 212_000, outputTokens: 96_000)
                }))
            },
            {
                // Delete All Data… opens the sheet that asks first. Settings' rows
                // are drawn in views of their own, so a click there may miss; the
                // check then asks for the sheet as the button does.
                let holder = ShotModel()
                return Shot(name: "settings-delete-click", width: 700, height: 800, toolbar: false, act: { window in
                    _ = scrollToEnd(in: window)
                    let clicked = click(target: "delete-all-data", in: window)
                    RunLoop.main.run(until: Date().addingTimeInterval(1))
                    var line = clicked + "; sheet open: \(window.attachedSheet != nil)"
                    if window.attachedSheet == nil {
                        holder.model?.isShowingDeleteAll = true
                        RunLoop.main.run(until: Date().addingTimeInterval(1))
                        line += "; asked for directly, sheet open: \(window.attachedSheet != nil)"
                    }
                    return line
                }) {
                    let model = sample { model in
                        model.libraryURL = URL(filePath: "/Users/student/Documents/School")
                    }
                    holder.model = model
                    return AnyView(SettingsView(pane: .ai).environment(model))
                }
            }(),
            Shot(name: "delete-all", width: 540, height: 640, toolbar: false) {
                AnyView(DeleteAllDataSheet().environment(sample { model in
                    model.libraryURL = URL(filePath: "/Users/student/Documents/School")
                    model.hasClaudeKey = true
                    model.usesReminders = true
                }))
            },
            // Delete All Data in the sheet starts deleting. The deleting itself is
            // a task, which can't run until the shots are drawn, so the self-test checks it.
            Shot(name: "delete-all-click", width: 540, height: 460, toolbar: false, act: { window in
                let clicked = click(target: "confirm-delete-all", in: window)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                return clicked + "; deleting: \(ShotTargets.frames["deleting-data"] != nil)"
            }) {
                AnyView(DeleteAllDataSheet().environment(sample { model in
                    model.libraryURL = URL(filePath: "/Users/student/Documents/School")
                }))
            },
            Shot(name: "delete-all-done", width: 540, height: 360, toolbar: false) {
                AnyView(DeleteAllDataSheet(report: DeletionReport(removedReminders: 6, removedRemindersList: true)).environment(sample { _ in }))
            },
            Shot(name: "delete-all-problem", width: 540, height: 420, toolbar: false) {
                let problem = String(localized: "Your Claude key couldn't be removed from the keychain. Delete “\(Keychain.claudeKey.label)” in Keychain Access.")
                return AnyView(DeleteAllDataSheet(report: DeletionReport(problems: [problem])).environment(sample { _ in }))
            },
            Shot(name: "settings-background", width: 700, height: 600, toolbar: false) {
                AnyView(SettingsView(pane: .background).environment(sample { model in
                    var downloads = WatchedFolder.downloads
                    downloads.isOn = true
                    model.watchedFolders = [downloads]
                }))
            },
            Shot(name: "new-subject", width: 460, height: 330, toolbar: false) { AnyView(NewSubjectSheet().environment(sample { _ in })) },
            Shot(name: "assessment-sheet", width: 520, height: 640, toolbar: false) {
                let model = sample { _ in }
                return AnyView(AssessmentSheet(assessment: model.assessments.first { $0.title == "Poetry analysis essay" }).environment(model))
            },
            Shot(name: "assessment-sheet-marked", width: 520, height: 640, toolbar: false) {
                let model = sample { _ in }
                return AnyView(AssessmentSheet(assessment: model.assessments.first { $0.status == .marked }).environment(model))
            },
            Shot(name: "exams-sheet", width: 640, height: 420, toolbar: false) { AnyView(ExamsSheet().environment(sample { _ in })) },
            Shot(name: "study", height: 1260) {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    planning(model)
                    model.destination = .study
                }))
            },
            Shot(name: "study-empty") {
                AnyView(ShotRoot().environment(sample { model in
                    newStudent(model)
                    model.destination = .study
                }))
            },
            Shot(name: "subject-study", height: 1060) {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    model.destination = .subject(model.subjects[2].id)
                }))
            },
            Shot(name: "today-studying") {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    focusing(model)
                    model.destination = .today
                }))
            },
            Shot(name: "library-search") {
                let model = sample { model in
                    studying(model)
                    model.destination = .library
                }
                let s = model.subjects
                let hits = [
                    SearchHit(file: SortedFile(name: "Electromagnetism notes.docx", subjectID: s[2].id, folder: "Notes", sortedAt: .now.addingTimeInterval(-86_400 * 3), url: URL(filePath: "/tmp/Electromagnetism notes.docx")), matched: ["induction", "electromagnetic"]),
                    SearchHit(file: SortedFile(name: "Lesson 14 slides.pdf", subjectID: s[2].id, folder: "Slides", sortedAt: .now.addingTimeInterval(-86_400 * 9), url: URL(filePath: "/tmp/Lesson 14 slides.pdf")), matched: ["induction"]),
                    SearchHit(file: SortedFile(name: "2021-hsc-physics.pdf", subjectID: s[2].id, folder: "Past Papers", sortedAt: .now.addingTimeInterval(-86_400 * 20), url: URL(filePath: "/tmp/2021-hsc-physics.pdf")), matched: ["induction"]),
                ]
                return AnyView(ShotRootLibrary(query: "electromagnetic induction", hits: hits).environment(model))
            },
            Shot(name: "review", width: 600, height: 480, toolbar: false) {
                let model = sample { studying($0) }
                return AnyView(ReviewSheet(cards: model.dueCards(), showsAnswer: true).environment(model))
            },
            Shot(name: "make-cards", width: 620, height: 560, toolbar: false) {
                let model = sample { studying($0) }
                let written = CardWriting(
                    drafts: [
                        CardDraft(question: "What is Faraday's law?", answer: "An emf is induced in a conductor when the magnetic flux through it changes.", quote: "Faraday's law: an emf is induced in a conductor when the magnetic flux through it changes."),
                        CardDraft(question: "What are eddy currents?", answer: "Loops of current induced in a solid conductor moving through a magnetic field, which oppose the motion.", quote: "Eddy currents are loops of current induced in a solid conductor moving through a magnetic field, or in a changing field."),
                        CardDraft(question: "How does an ideal transformer relate voltage and turns?", answer: "Vp/Vs = Np/Ns", quote: "For an ideal transformer, Vp/Vs = Np/Ns, and the power in equals the power out, so VpIp = VsIs."),
                        CardDraft(question: "Why is power transmitted at high voltage?", answer: "High voltage means low current, which reduces the energy lost as heat in the wires.", quote: "Power stations use step-up transformers so electricity is transmitted at high voltage and low current, which reduces energy lost as heat in the wires (P = I²R)."),
                        CardDraft(question: "What does a DC generator use instead of slip rings?", answer: "A split ring commutator, which reverses the connection every half turn."),
                    ],
                    sourceName: "Electromagnetism notes.docx",
                    dropped: 1
                )
                return AnyView(MakeCardsSheet(subjectID: model.subjects[2].id, written: written).environment(model))
            },
            // Choosing a file: Write Cards should come on once a row is clicked.
            Shot(name: "make-cards-click", width: 620, height: 560, toolbar: false, act: clickFirstRow) {
                let model = sample { studying($0) }
                return AnyView(MakeCardsSheet(subjectID: model.subjects[2].id).environment(model))
            },
            // Opened from a file's menu, with that file already chosen.
            Shot(name: "make-cards-file", width: 620, height: 560, toolbar: false, act: listSelection) {
                let model = sample { studying($0) }
                let file = model.libraryFiles.first { $0.name == "2021-hsc-physics.pdf" }
                return AnyView(MakeCardsSheet(subjectID: model.subjects[2].id, file: file?.url).environment(model))
            },
            // A Claude key saved: Claude is chosen, and the file already has cards.
            Shot(name: "make-cards-claude", width: 620, height: 560, toolbar: false, act: listSelection) {
                let model = sample { model in
                    studying(model)
                    model.hasClaudeKey = true
                    model.libraryFiles.append(SortedFile(name: "Electromagnetism notes.docx", subjectID: model.subjects[2].id, folder: "Notes", sortedAt: .now, url: URL(filePath: "/tmp/Electromagnetism notes.docx")))
                }
                return AnyView(MakeCardsSheet(subjectID: model.subjects[2].id, file: URL(filePath: "/tmp/Electromagnetism notes.docx")).environment(model))
            },
            // Claude's cards from a long file, stopped partway by the student's account.
            Shot(name: "make-cards-many", width: 620, height: 560, toolbar: false) {
                let model = sample { studying($0) }
                let written = CardWriting(
                    drafts: (1...40).map { CardDraft(question: "What is defined in rule \($0)?", answer: "The quantity measured in step \($0) of the method.", quote: "Rule \($0) defines the quantity measured in step \($0) of the method.") },
                    origin: .claude,
                    sourceName: "Physics textbook chapter 7.pdf",
                    note: String(localized: "Claude stopped before the end of the file: \(ClaudeVoter.Problem.billing("").message)")
                )
                return AnyView(MakeCardsSheet(subjectID: model.subjects[2].id, written: written).environment(model))
            },
            // Every card reviewed: Practise Anyway instead of Start Review.
            Shot(name: "study-reviewed", height: 1260) {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    reviewedEverything(model)
                    model.destination = .study
                }))
            },
            {
                let holder = ShotModel()
                return Shot(name: "study-practise-click", act: { window in
                    let clicked = click(target: "practise-anyway", in: window)
                    RunLoop.main.run(until: Date().addingTimeInterval(1))
                    let practice = holder.model?.practiceCards().count ?? 0
                    return clicked + "; sheet open: \(window.attachedSheet != nil); cards to practise: \(practice)"
                }) {
                    let model = sample { model in
                        studying(model)
                        reviewedEverything(model)
                        model.destination = .study
                    }
                    holder.model = model
                    return AnyView(ShotRoot().environment(model))
                }
            }(),
            Shot(name: "practice", width: 600, height: 480, toolbar: false) {
                let model = sample { model in
                    studying(model)
                    reviewedEverything(model)
                }
                return AnyView(ReviewSheet(cards: model.practiceCards(in: model.subjects[2].id), subjectID: model.subjects[2].id, isPractice: true, showsAnswer: true).environment(model))
            },
            Shot(name: "progress", height: 1640) {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    planning(model)
                    progressing(model)
                    model.destination = .progress
                }))
            },
            Shot(name: "progress-empty") {
                AnyView(ShotRoot().environment(sample { model in
                    newStudent(model)
                    model.destination = .progress
                }))
            },
            Shot(name: "today-progress") {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    progressing(model)
                    model.destination = .today
                }))
            },
            Shot(name: "subject-progress", height: 1700) {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    progressing(model)
                    model.destination = .subject(model.subjects[0].id)
                }))
            },
            Shot(name: "weekly-review", width: 520, height: 640, toolbar: false) {
                let model = sample { model in
                    studying(model)
                    planning(model)
                    progressing(model)
                }
                return AnyView(WeeklyReviewSheet(weekStart: model.weekStart(containing: .now)).environment(model))
            },
            Shot(name: "term-summary", width: 600, height: 520, toolbar: false) {
                let model = sample { progressing($0) }
                let term = model.pastTerms().first ?? TermRequest(title: "", subjectIDs: [])
                return AnyView(TermSummarySheet(request: term).environment(model))
            },
            {
                // Start Earlier sets a start day on the work due in the busy week.
                let holder = ShotModel()
                return Shot(name: "progress-start-earlier", height: 1640, act: { window in
                    guard let model = holder.model else { return "no model" }
                    let clicked = click(target: "start-earlier", in: window)
                    let started = model.assessments.filter { $0.planFrom != nil }.map(\.title)
                    return clicked + "; starting earlier: " + started.joined(separator: ", ")
                }) {
                    let model = sample { model in
                        studying(model)
                        progressing(model)
                        model.destination = .progress
                    }
                    holder.model = model
                    return AnyView(ShotRoot().environment(model))
                }
            }(),
            {
                // Plan Next Week in the review plans the week after.
                let holder = ShotModel()
                return Shot(name: "review-plan-next", width: 520, height: 640, toolbar: false, act: { window in
                    guard let model = holder.model else { return "no model" }
                    let next = model.calendar.date(byAdding: .weekOfYear, value: 1, to: model.weekStart(containing: .now))!
                    let end = model.calendar.date(byAdding: .day, value: 7, to: next)!
                    let before = model.sessions.filter { $0.start >= next && $0.start < end }.count
                    let clicked = click(target: "plan-next-week", in: window)
                    let after = model.sessions.filter { $0.start >= next && $0.start < end }.count
                    return clicked + "; sessions next week: \(before) → \(after)"
                }) {
                    let model = sample { model in
                        studying(model)
                        progressing(model)
                    }
                    holder.model = model
                    return AnyView(WeeklyReviewSheet(weekStart: model.weekStart(containing: .now)).environment(model))
                }
            }(),
            Shot(name: "today-plan") {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    planning(model)
                    model.destination = .today
                }))
            },
            Shot(name: "planner-plans") {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    planning(model)
                    model.destination = .planner
                }))
            },
            Shot(name: "subject-todos", height: 1180) {
                AnyView(ShotRoot().environment(sample { model in
                    studying(model)
                    planning(model)
                    model.destination = .subject(model.subjects[2].id)
                }))
            },
            Shot(name: "session-sheet", width: 500, height: 640, toolbar: false) {
                let model = sample { model in
                    studying(model)
                    planning(model)
                }
                // Tomorrow's work on the report, with a step typed in and a to-do for it.
                let report = model.assessments.first { $0.title == "Projectile motion report" }
                let start = model.calendar.date(byAdding: .day, value: 1, to: model.calendar.startOfDay(for: .now))!.addingTimeInterval(16 * 3600)
                let session = StudySession(
                    subjectID: model.subjects[2].id, start: start, end: start.addingTimeInterval(90 * 60), assessmentID: report?.id,
                    title: report?.title, plan: [PlanStep(title: "Write the method section", isDone: true), model.todos[0].step], isOwn: true
                )
                model.sessions.append(session)
                return AnyView(SessionSheet(session: session).environment(model))
            },
            Shot(name: "session-sheet-new", width: 500, height: 640, toolbar: false) {
                let model = sample { model in
                    studying(model)
                    planning(model)
                }
                let tomorrow = model.calendar.date(byAdding: .day, value: 1, to: model.calendar.startOfDay(for: .now))!.addingTimeInterval(16.5 * 3600)
                return AnyView(SessionSheet(session: nil, start: tomorrow, subjectID: model.subjects[2].id).environment(model))
            },
            Shot(name: "todo-sheet", width: 420, height: 330, toolbar: false) {
                let model = sample { model in
                    planning(model)
                }
                return AnyView(TodoSheet(todo: model.todos[0]).environment(model))
            },
            {
                // The timer with a plan: clicking the second tick box ticks off
                // that step, and the to-do it came from.
                let holder = ShotModel()
                return Shot(name: "focus-plan", width: 320, height: 700, toolbar: false, act: { window in
                    guard let model = holder.model, let id = model.focus?.sessionID, let step = model.session(id)?.plan.dropFirst().first else { return "no plan" }
                    let clicked = click(target: "step-\(step.id)", in: window)
                    let plan = model.session(id)?.plan ?? []
                    return clicked + "; plan now: " + plan.map { "\($0.title)\($0.isDone ? " ✓" : "")" }.joined(separator: ", ")
                        + "; to-do done: \(model.todo(for: step)?.isDone == true)"
                }) {
                    let model = sample { model in
                        studying(model)
                        planning(model)
                        focusing(model, plan: [
                            PlanStep(title: "Write the method section"),
                            PlanStep(title: "Redo question 4 of the practical", kind: .todo, reference: model.todos[0].id.uuidString),
                            PlanStep(title: "Review 3 cards", kind: .cards),
                        ])
                    }
                    holder.model = model
                    return AnyView(FocusWindow().environment(model))
                }
            }(),
            {
                // Clicking Folio's first idea adds it to the plan.
                let holder = ShotModel()
                return Shot(name: "focus-plan-empty", width: 320, height: 760, toolbar: false, act: { window in
                    let clicked = click(target: "suggestion-0", in: window)
                    let plan = holder.model.flatMap { model in model.focus?.sessionID.flatMap(model.session) }?.plan ?? []
                    return clicked + "; plan now: " + plan.map(\.title).joined(separator: ", ")
                }) {
                    let model = sample { model in
                        studying(model)
                        planning(model)
                        focusing(model, plan: [])
                    }
                    holder.model = model
                    return AnyView(FocusWindow().environment(model))
                }
            }(),
            {
                // Ticking a to-do off the list.
                let holder = ShotModel()
                return Shot(name: "todo-list", width: 640, height: 420, toolbar: false, act: { window in
                    guard let model = holder.model, let first = model.openTodos().first else { return "no to-dos" }
                    let clicked = click(target: "todo-\(first.id)", in: window)
                    return clicked + "; done: \(model.todos.first { $0.id == first.id }?.isDone == true)"
                }) {
                    let model = sample { planning($0) }
                    holder.model = model
                    return AnyView(TodoList(subjectID: nil).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.windowBackground).environment(model))
                }
            }(),
            {
                // Edit Plan… on Today opens the session to plan.
                return Shot(name: "today-plan-click", act: { window in
                    let clicked = click(target: "plan-session", in: window)
                    RunLoop.main.run(until: Date().addingTimeInterval(1))
                    return clicked + "; sheet open: \(window.attachedSheet != nil)"
                }) {
                    AnyView(ShotRoot().environment(sample { model in
                        planning(model)
                        model.destination = .today
                    }))
                }
            }(),
            {
                // With nothing planned, Today's button plans the week it offers:
                // this one, or from Sunday midday the next.
                let holder = ShotModel()
                return Shot(name: "today-plan-week-click", act: { window in
                    guard let model = holder.model else { return "no model" }
                    let week = model.weekToPlan()
                    let end = model.calendar.date(byAdding: .day, value: 7, to: week)!
                    let before = model.sessions.filter { $0.start >= week && $0.start < end }.count
                    let clicked = click(target: "plan-week", in: window)
                    let after = model.sessions.filter { $0.start >= week && $0.start < end }.count
                    return clicked + "; sessions in the week of \(week.formatted(date: .abbreviated, time: .omitted)): \(before) → \(after)"
                }) {
                    let model = sample { model in
                        model.sessions = []
                        model.destination = .today
                    }
                    holder.model = model
                    return AnyView(ShotRoot().environment(model))
                }
            }(),
            {
                // Clicking a session in the planner opens it to change.
                let holder = ShotModel()
                return Shot(name: "planner-click", act: { window in
                    let now = Date.now
                    guard let model = holder.model,
                          let session = model.sessions.filter({ model.calendar.isDate($0.start, equalTo: now, toGranularity: .weekOfYear) }).min(by: { $0.start < $1.start })
                    else { return "no session this week" }
                    // Sessions sit in the grid by an offset from the top of their day.
                    let time = model.calendar.dateComponents([.hour, .minute], from: session.start)
                    let minutes = (time.hour ?? 0) * 60 + (time.minute ?? 0) - CalendarGrid.firstHour * 60
                    let clicked = click(target: "session-\(session.id)", in: window, lowered: CGFloat(minutes) * CalendarGrid.hourHeight / 60 + 1)
                    RunLoop.main.run(until: Date().addingTimeInterval(1))
                    return clicked + "; sheet open: \(window.attachedSheet != nil)"
                }) {
                    let model = sample { model in
                        planning(model)
                        model.destination = .planner
                    }
                    holder.model = model
                    return AnyView(ShotRoot().environment(model))
                }
            }(),
            Shot(name: "focus-finish-plan", width: 320, height: 760, toolbar: false) {
                AnyView(FocusWindow().environment(sample { model in
                    studying(model)
                    planning(model)
                    focusing(model, plan: [
                        PlanStep(title: "Write the method section", isDone: true),
                        PlanStep(title: "Draw the range graph"),
                    ])
                    model.focus?.isOver = true
                    model.focus?.banked = 52 * 60
                    model.focus?.runningSince = nil
                }))
            },
            Shot(name: "focus", width: 320, height: 520, toolbar: false) {
                AnyView(FocusWindow().environment(sample { focusing($0) }))
            },
            Shot(name: "focus-finish", width: 320, height: 620, toolbar: false) {
                AnyView(FocusWindow().environment(sample { focusing($0, over: true) }))
            },
            Shot(name: "whats-this", width: 500, height: 330, toolbar: false) {
                let model = sample { studying($0) }
                let file = SortedFile(name: "Lecture 6.mp4", subjectID: model.subjects[2].id, folder: "Videos", sortedAt: .now, url: URL(filePath: "/tmp/Lecture 6.mp4"))
                return AnyView(WhatsThisSheet(file: file, points: [
                    "A projectile moves under gravity alone once it's launched.",
                    "Its horizontal velocity stays constant, while its vertical velocity changes at 9.8 m/s² downwards.",
                    "The path is a parabola, and the time of flight depends only on the vertical motion.",
                ]).environment(model))
            },
            Shot(name: "practise", width: 440, height: 330, toolbar: false) {
                let model = sample { studying($0) }
                let physics = model.subjects[2]
                return AnyView(PractiseSheet(paper: model.papers(of: physics.id)[0], subject: physics).environment(model))
            },
            Shot(name: "menubar-focus", width: 320, height: 560, toolbar: false) {
                AnyView(MenuBarView().environment(sample { model in
                    studying(model)
                    focusing(model)
                }))
            },
            Shot(name: "menubar", width: 320, height: 470, toolbar: false) {
                AnyView(MenuBarView().environment(sample { model in
                    var downloads = WatchedFolder.downloads
                    downloads.isOn = true
                    model.watchedFolders = [downloads]
                }))
            },
        ]
    }
}
#endif
