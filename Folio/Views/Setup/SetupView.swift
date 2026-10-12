import AppKit
import SwiftUI
import FolioKit

/// First-run setup, shown in the main window until there's a School folder:
/// a welcome, then five steps with a list of them down the side.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var setup: SetupModel

    /// - Parameter setup: Choices so far, for previews.
    init(setup: SetupModel = SetupModel()) {
        _setup = State(initialValue: setup)
    }

    var body: some View {
        Group {
            if model.needsLibraryAgain {
                RelinkView()
            } else if setup.showsWelcome {
                WelcomeView(setup: setup)
            } else {
                HStack(spacing: 0) {
                    SetupSidebar(setup: setup, skip: { finish(plansFirstWeek: false) })
                    StepContent(setup: setup, finish: finish)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // The sidebar runs up under the transparent title bar, as in the main window.
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBackground)
    }

    /// Saves everything and opens Folio. A new Folio folder in Documents is
    /// made first if the student didn't choose a folder.
    private func finish(plansFirstWeek: Bool) {
        if setup.library == nil, let folder = HomeFolderPanel.makeFolioFolder() {
            setup.useLibrary(folder)
        }
        guard let library = setup.library else { return }
        if setup.pack == nil, let general = PackLibrary.pack(PackLibrary.otherID) {
            setup.choose(general)
        }
        model.finishSetup(
            library: library,
            profile: setup.makeProfile(),
            watchesDownloads: setup.watchesDownloads,
            watchedFolders: setup.watchedFolders.filter { $0.standardizedFileURL != library.standardizedFileURL },
            plansFirstWeek: plansFirstWeek
        )
    }
}

// MARK: Sidebar

private struct SetupSidebar: View {
    let setup: SetupModel
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folio")
                        .font(.system(size: 17, weight: .semibold))
                    Text("First-time setup")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.top, 80)
            .padding(.horizontal, 4)
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(SetupModel.Step.allCases) { step in
                    StepRow(step: step, current: setup.step, reached: setup.reached) {
                        withAnimation(Theme.motion()) { setup.go(to: step) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Setup steps")

            Spacer(minLength: 24)

            Button("Skip setup", action: skip)
                .buttonStyle(.folioLink)
                .help("Start with the suggested subjects, sorting into a Folio folder in Documents")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Color(hex: 0x171719))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
        }
    }
}

private struct StepRow: View {
    let step: SetupModel.Step
    let current: SetupModel.Step
    let reached: SetupModel.Step
    let action: () -> Void
    @State private var isHovered = false

    private var isCurrent: Bool { step == current }
    private var isDone: Bool { step.rawValue < current.rawValue || (step.rawValue <= reached.rawValue && !isCurrent) }
    private var canGo: Bool { step.rawValue <= reached.rawValue }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isDone ? Theme.accentFill : .clear)
                    Circle()
                        .strokeBorder(isCurrent ? Theme.accent : isDone ? .clear : Color.white.opacity(0.28), lineWidth: 1.5)
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isDone ? Color.white : isCurrent ? Theme.accent : Theme.secondaryText)
                }
                .frame(width: 24, height: 24)
                Text(step.title)
                    .font(.system(size: 14, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(isCurrent ? Theme.primaryText : Theme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10).fill(isCurrent ? Color.white.opacity(0.08) : isHovered && canGo ? Color.white.opacity(0.05) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canGo)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Step \(step.rawValue + 1): \(step.title)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: Steps

private struct StepContent: View {
    let setup: SetupModel
    let finish: (Bool) -> Void

    var body: some View {
        switch setup.step {
        case .school: SchoolStep(setup: setup)
        case .subjects: SubjectsStep(setup: setup)
        case .folders: FoldersStep(setup: setup)
        case .week: WeekStep(setup: setup)
        case .done: DoneStep(setup: setup, finish: finish)
        }
    }
}

/// The layout every step shares: the step number, a title and a line about
/// it, the step's controls, and Back and Continue at the bottom.
private struct StepPage<Content: View, Footer: View>: View {
    let setup: SetupModel
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Step \(setup.step.rawValue + 1) of \(SetupModel.Step.allCases.count)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                        Text(title)
                            .font(.system(size: 30, weight: .semibold))
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                        Text(message)
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.primaryText.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                    content
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 80)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 12) {
                footer
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 56)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BackButton: View {
    let setup: SetupModel

    var body: some View {
        Button("Back") {
            withAnimation(Theme.motion()) {
                if let previous = SetupModel.Step(rawValue: setup.step.rawValue - 1) {
                    setup.go(to: previous)
                } else {
                    setup.showsWelcome = true
                }
            }
        }
        .buttonStyle(.folioGhostLarge)
        .keyboardShortcut(.cancelAction)
    }
}

private struct ContinueButton: View {
    let setup: SetupModel
    var title: LocalizedStringKey = "Continue"
    var isEnabled = true
    var before: () -> Bool = { true }

    var body: some View {
        Button(title) {
            guard before(), let next = SetupModel.Step(rawValue: setup.step.rawValue + 1) else { return }
            withAnimation(Theme.motion()) { setup.go(to: next) }
        }
        .buttonStyle(.folioPrimaryLarge)
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
    }
}

// MARK: 1. Where you study

private struct SchoolStep: View {
    let setup: SetupModel

    /// A group of packs' heading: the country's name in the student's
    /// language, or "International".
    static func heading(for packs: [CurriculumPack], named name: String) -> String {
        if let code = packs.first?.regionCodes.first, let country = Locale.current.localizedString(forRegionCode: code) {
            return country
        }
        return name == "International" ? String(localized: "International") : name
    }

    /// A pack's name, with University and Another school in the student's language.
    static func displayName(of pack: CurriculumPack) -> String {
        switch pack.id {
        case PackLibrary.universityID: String(localized: "University")
        case PackLibrary.otherID: String(localized: "Another school")
        default: pack.name
        }
    }

    var body: some View {
        StepPage(
            setup: setup,
            title: "Where do you study?",
            message: "Folio starts with your school system's subjects, the exams you sit and the kinds of documents you keep. You can change any of it later."
        ) {
            ForEach(PackLibrary.groups(), id: \.name) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.name.isEmpty ? String(localized: "Something else") : Self.heading(for: group.packs, named: group.name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 4)
                    VStack(spacing: 8) {
                        ForEach(group.packs) { pack in
                            PackChoice(pack: pack, isSelected: setup.pack?.id == pack.id) {
                                withAnimation(Theme.motion()) { setup.choose(pack) }
                            }
                        }
                    }
                }
            }
        } footer: {
            BackButton(setup: setup)
            Spacer()
            ContinueButton(setup: setup, isEnabled: setup.pack != nil)
        }
    }
}

private struct PackChoice: View {
    let pack: CurriculumPack
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var detail: String {
        switch pack.id {
        case PackLibrary.universityID: String(localized: "Courses come from your timetable, or you type their codes")
        case PackLibrary.otherID: String(localized: "Common subjects, for any school")
        default: pack.fullName ?? ""
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SchoolStep.displayName(of: pack))
                        .font(.system(size: 15, weight: .medium))
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(isHovered ? Theme.cardHover : Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: 2. Subjects

private struct SubjectsStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var setup: SetupModel
    @State private var isAddingOwn = false
    @State private var ownName = ""
    @State private var isBrowsing = false
    @State private var timetableNote: String?
    @FocusState private var ownFieldFocused: Bool

    private var count: Int { setup.includedSubjects.count }

    var body: some View {
        StepPage(
            setup: setup,
            title: "What are you studying?",
            message: setup.isUniversity
                ? "Folio files into a folder for each course. Add your courses from your timetable, or type their codes. Course codes in file names are the strongest clue Folio has."
                : "Folio files your work into these subjects and colours them across the app. You can change them any time."
        ) {
            if setup.isUniversity {
                universityCourses
            } else {
                FlowLayout(spacing: 10) {
                    ForEach(setup.drafts) { draft in
                        SubjectChip(name: draft.subject.name, colour: Color(hex: draft.subject.colorHex), isOn: draft.isIncluded) {
                            withAnimation(Theme.motion()) { setup.toggle(draft.id) }
                        }
                    }
                    if isAddingOwn {
                        TextField("Subject", text: $ownName, prompt: Text("Subject name"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .focused($ownFieldFocused)
                            .onSubmit(addOwn)
                            .padding(.horizontal, 16)
                            .frame(width: 180, height: 40)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .onExitCommand { isAddingOwn = false }
                    } else {
                        AddChip(title: "Add your own") {
                            isAddingOwn = true
                            ownFieldFocused = true
                        }
                    }
                }
                if let pack = setup.pack, pack.subjects.count > setup.drafts.count {
                    Button("Browse all \(pack.subjects.count) \(pack.name) courses…") { isBrowsing = true }
                        .buttonStyle(.folioLink)
                }
            }
            if !setup.subjectsAreValid && count > 0 {
                Text("Each subject needs a name, and no two can share one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warning)
            }
        } footer: {
            BackButton(setup: setup)
            Text("\(count) selected")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ContinueButton(setup: setup, isEnabled: setup.subjectsAreValid)
        }
        .sheet(isPresented: $isBrowsing) {
            if let pack = setup.pack {
                CoursePicker(pack: pack, isChosen: setup.isChosen) { setup.toggle($0) }
            }
        }
    }

    private func addOwn() {
        withAnimation(Theme.motion()) { setup.addOwn(named: ownName) }
        ownName = ""
        isAddingOwn = false
    }

    @ViewBuilder private var universityCourses: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await addCoursesFromTimetable() }
            } label: {
                Label("Add Courses from Your Timetable…", systemImage: "calendar")
            }
            .buttonStyle(.folioGhost)
            Text(timetableNote ?? String(localized: "Folio reads course codes like COMP1511 from your calendar. Subscribe to your uni's timetable in Calendar first."))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !setup.drafts.isEmpty {
            VStack(spacing: 0) {
                ForEach($setup.drafts) { $draft in
                    SubjectDraftRow(draft: $draft, showsCode: true)
                    if draft.id != setup.drafts.last?.id {
                        Rectangle().fill(Theme.separator).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.cardBackground))
        }
        HStack(spacing: 12) {
            Button {
                withAnimation(Theme.motion()) { setup.addCourse() }
            } label: {
                Label("Add Course", systemImage: "plus")
            }
            .buttonStyle(.folioGhost)
            Spacer()
            Text("This term")
                .font(.system(size: 13, weight: .medium))
            TextField("This term", text: $setup.termName, prompt: Text(verbatim: TermStyle.regional.nextName()))
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
        }
    }

    /// Reads course codes from the student's calendars and adds them as courses.
    private func addCoursesFromTimetable() async {
        if !model.isCalendarConnected {
            await model.connectCalendar()
        }
        guard model.isCalendarConnected else {
            timetableNote = String(localized: "Folio needs to see your calendar for this. You can allow it in System Settings › Privacy & Security › Calendars, or type your courses below.")
            return
        }
        let found = model.coursesInCalendar()
        guard !found.courses.isEmpty else {
            timetableNote = String(localized: "No course codes in your calendars over the next four weeks. Subscribe to your uni's timetable in Calendar, or type your courses below.")
            return
        }
        withAnimation(Theme.motion()) { setup.addCourses(found.courses) }
        model.useAsTimetable(found.calendarIDs)
        timetableNote = String(localized: "Added \(found.courses.count) courses from your timetable.")
    }
}

/// A subject the student can tick: tinted with its colour when chosen.
struct SubjectChip: View {
    let name: String
    let colour: Color
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(name)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(isOn ? colour.mixed(with: .white, by: 0.45) : Theme.primaryText.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Capsule().fill(isOn ? colour.opacity(isHovered ? 0.32 : 0.24) : Color.white.opacity(isHovered ? 0.13 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(name)
        .accessibilityValue(isOn ? "Chosen" : "Not chosen")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct AddChip: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primaryText.opacity(0.85))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(Color.white.opacity(isHovered ? 0.06 : 0)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: 3. Folders

private struct FoldersStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var setup: SetupModel

    var body: some View {
        StepPage(
            setup: setup,
            title: setup.isUniversity ? "Where does your uni work end up?" : "Where does your schoolwork end up?",
            message: "Folio watches the folders you choose and sorts anything new that lands there. It only looks at the folders you turn on."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    FolderRow(systemImage: "arrow.down.to.line", title: String(localized: "Downloads"), path: "~/Downloads", isOn: $setup.watchesDownloads)
                    divider
                    FolderRow(systemImage: "menubar.dock.rectangle", title: HomeFolderPanel.Kind.desktop.displayName, path: "~/Desktop", isOn: watching(.desktop))
                    divider
                    FolderRow(systemImage: "folder", title: HomeFolderPanel.Kind.documents.displayName, path: "~/Documents", isOn: watching(.documents))
                    ForEach(setup.watchedFolders.filter { HomeFolderPanel.Kind(of: $0) == nil }, id: \.self) { folder in
                        divider
                        FolderRow(systemImage: "folder", title: folder.lastPathComponent, path: HomeFolderPanel.tildePath(folder), isOn: Binding(
                            get: { true },
                            set: { on in if !on { setup.watchedFolders.removeAll { $0 == folder } } }
                        ))
                    }
                }
                .padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.cardBackground))

                Button("Choose Another Folder…") {
                    if let folder = HomeFolderPanel.chooseFolderToWatch(), !setup.watchedFolders.contains(folder) {
                        setup.watchedFolders.append(folder)
                    }
                }
                .buttonStyle(FilledButtonStyle(kind: .ghost, height: 36))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Sorted files are kept in")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 4)
                HStack(spacing: 14) {
                    IconTile(systemName: "folder", foreground: Theme.primaryText.opacity(0.85), background: Color.white.opacity(0.1))
                    Text(setup.libraryDescription)
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 8)
                    Button("Change…") {
                        if let folder = SchoolFolderPanel.choose() {
                            withAnimation(Theme.motion()) { setup.useLibrary(folder) }
                        }
                    }
                    .buttonStyle(.folioLink)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.cardBackground))
                if let note = foundFolders {
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            BackButton(setup: setup)
            Spacer()
            ContinueButton(setup: setup) {
                // The sandbox needs the student's say-so before Folio can make its folder in Documents.
                if setup.library == nil, let folder = HomeFolderPanel.makeFolioFolder() {
                    setup.useLibrary(folder)
                }
                return setup.library != nil
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
    }

    /// The student's own subject folders Folio found in the chosen folder.
    private var foundFolders: String? {
        let found = setup.drafts.filter { $0.isIncluded && $0.existingFolder != nil }
        guard !found.isEmpty else { return nil }
        let names = found.prefix(4).map { "“\($0.existingFolder ?? "")”" }
        if found.count > 4 {
            let list = (names + [String(localized: "\(found.count - 4) more")]).formatted(.list(type: .and))
            return String(localized: "Uses your folders \(list).")
        }
        return found.count == 1
            ? String(localized: "Uses your folder \(names[0]).")
            : String(localized: "Uses your folders \(names.formatted(.list(type: .and))).")
    }

    /// Turning on Desktop or Documents asks macOS to let Folio see it.
    private func watching(_ kind: HomeFolderPanel.Kind) -> Binding<Bool> {
        Binding(
            get: { setup.watchedFolders.contains { HomeFolderPanel.Kind(of: $0) == kind } },
            set: { on in
                if on {
                    if let folder = HomeFolderPanel.allow(kind) { setup.watchedFolders.append(folder) }
                } else {
                    setup.watchedFolders.removeAll { HomeFolderPanel.Kind(of: $0) == kind }
                }
            }
        )
    }
}

private struct FolderRow: View {
    let systemImage: String
    let title: String
    let path: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: systemImage, foreground: Theme.primaryText.opacity(0.85), background: Color.white.opacity(0.1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(path)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            Toggle("Watch \(title)", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .frame(minHeight: 68)
    }
}

// MARK: 4. Your week

private struct WeekStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var setup: SetupModel
    @State private var editingTimetable = false

    /// Monday first, with the calendar's own letters and names, such as "L" for lundi.
    private static var days: [(weekday: Int, letter: String, name: String)] {
        let calendar = Calendar.current
        return [2, 3, 4, 5, 6, 7, 1].map { ($0, calendar.veryShortStandaloneWeekdaySymbols[$0 - 1], calendar.standaloneWeekdaySymbols[$0 - 1]) }
    }

    var body: some View {
        StepPage(
            setup: setup,
            title: "Tell Folio about your week",
            message: setup.isUniversity
                ? "It plans study sessions around your classes and the times you like to study."
                : "It plans study sessions around school and the times you like to study."
        ) {
            if !setup.isUniversity {
                VStack(alignment: .leading, spacing: 10) {
                    label("School days")
                    HStack(spacing: 8) {
                        ForEach(Self.days, id: \.weekday) { day in
                            DayButton(letter: day.letter, name: day.name, isOn: setup.schoolDays.contains(day.weekday)) {
                                if setup.schoolDays.contains(day.weekday) { setup.schoolDays.remove(day.weekday) } else { setup.schoolDays.insert(day.weekday) }
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    TimeField(title: "School starts", minutes: $setup.schoolStart)
                    TimeField(title: "School finishes", minutes: $setup.schoolEnd)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                label("When do you like to study?")
                FlowLayout(spacing: 10) {
                    ForEach(SetupModel.StudyTime.allCases) { time in
                        SubjectChip(name: time.title(atUniversity: setup.isUniversity), colour: Theme.accent, isOn: setup.studyTimes.contains(time)) {
                            if setup.studyTimes.contains(time) { setup.studyTimes.remove(time) } else { setup.studyTimes.insert(time) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                label("Session length")
                SegmentedChoice(options: SetupModel.sessionLengths, selection: $setup.sessionMinutes) { String(localized: "\($0) min", comment: "A study session's length, such as 45 min") }
            }

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    IconTile(systemName: "calendar", foreground: Theme.primaryText.opacity(0.85), background: Color.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan around my calendar")
                            .font(.system(size: 15, weight: .medium))
                        Text(model.isCalendarConnected ? "Connected. Folio reads your events and never changes them." : "Folio reads your events and never changes them.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    if model.isCalendarConnected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                            .accessibilityLabel("Connected")
                    } else {
                        Button("Connect…") { Task { await model.connectCalendar() } }
                            .buttonStyle(.folioLink)
                    }
                }
                .frame(minHeight: 68)

                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 1)

                HStack(spacing: 14) {
                    IconTile(systemName: "tablecells", foreground: Theme.primaryText.opacity(0.85), background: Color.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enter my timetable")
                            .font(.system(size: 15, weight: .medium))
                        Text(setup.timetable?.summary ?? String(localized: "One week, or Week A and Week B. Folio shows your classes and notices files from a lesson."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Button(setup.timetable == nil ? "Enter…" : "Edit…") { editingTimetable = true }
                        .buttonStyle(.folioLink)
                        .disabled(setup.includedSubjects.isEmpty)
                }
                .frame(minHeight: 68)
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.cardBackground))
            .sheet(isPresented: $editingTimetable) {
                TimetableEditor(
                    timetable: setup.timetableToEdit(calendar: model.calendar),
                    subjects: setup.includedSubjects,
                    weekdays: setup.isUniversity ? [2, 3, 4, 5, 6] : setup.schoolDays,
                    calendar: model.calendar,
                    onSave: { setup.timetable = $0 },
                    onRemove: setup.timetable == nil ? nil : { setup.timetable = nil }
                )
            }
        } footer: {
            BackButton(setup: setup)
            Spacer()
            ContinueButton(setup: setup)
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.leading, 2)
    }
}

private struct DayButton: View {
    let letter: String
    let name: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Theme.primaryText.opacity(0.85))
                .frame(width: 44, height: 44)
                .background(Circle().fill(isOn ? Theme.accentFill : Color.white.opacity(isHovered ? 0.13 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(name)
        .accessibilityValue(isOn ? "School day" : "Not a school day")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct TimeField: View {
    let title: LocalizedStringKey
    @Binding var minutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText.opacity(0.7))
            MinutePicker(minutes: $minutes)
                .datePickerStyle(.field)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A row of equal buttons with one chosen, like the design's session lengths.
private struct SegmentedChoice<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(option == selection ? Color.white : Theme.primaryText.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(option == selection ? Color.white.opacity(0.2) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
    }
}

// MARK: 5. All set

private struct DoneStep: View {
    let setup: SetupModel
    let finish: (Bool) -> Void

    var body: some View {
        StepPage(
            setup: setup,
            title: "You're all set",
            message: "Here's what Folio will do. You can change any of it later in Settings."
        ) {
            VStack(spacing: 0) {
                SummaryRow(systemImage: "folder", title: subjectsTitle, edit: { setup.go(to: .subjects) }) {
                    FlowLayout(spacing: 8) {
                        ForEach(setup.includedSubjects) { subject in
                            HStack(spacing: 6) {
                                SubjectDot(color: Color(hex: subject.colorHex))
                                Text(subject.name)
                            }
                        }
                    }
                }
                Rectangle().fill(Theme.separator).frame(height: 1)
                SummaryRow(systemImage: "arrow.down.to.line", title: watchingTitle, edit: { setup.go(to: .folders) }) {
                    Text("Sorted files go to \(setup.libraryDescription)")
                }
                Rectangle().fill(Theme.separator).frame(height: 1)
                SummaryRow(systemImage: "calendar", title: String(localized: "Study: \(setup.studyTimesDescription)", comment: "When the student likes to study, such as “Study: Evenings and Weekends”"), edit: { setup.go(to: .week) }) {
                    Text(weekDetail)
                }
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.cardBackground))
        } footer: {
            BackButton(setup: setup)
            Spacer()
            Button("Plan My First Week") { finish(true) }
                .buttonStyle(.folioGhostLarge)
            Button("Open Folio") { finish(false) }
                .buttonStyle(.folioPrimaryLarge)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var subjectsTitle: String {
        let count = setup.includedSubjects.count
        return setup.isUniversity ? String(localized: "\(count) courses") : String(localized: "\(count) subjects")
    }

    private var watchingTitle: String {
        var names = setup.watchesDownloads ? [String(localized: "Downloads")] : []
        names += setup.watchedFolders.map { HomeFolderPanel.Kind(of: $0)?.displayName ?? $0.lastPathComponent }
        return names.isEmpty
            ? String(localized: "Not watching any folders")
            : String(localized: "Watching \(names.formatted(.list(type: .and)))")
    }

    private var weekDetail: String {
        let session = String(localized: "\(setup.sessionMinutes)-minute sessions")
        if let timetable = setup.timetable {
            return String(localized: "\(session) · timetable: \(timetable.summary)")
        }
        guard !setup.isUniversity, !setup.schoolDays.isEmpty else { return session }
        let start = Self.time(setup.schoolStart), end = Self.time(setup.schoolEnd)
        let days = setup.schoolDays == [2, 3, 4, 5, 6] ? String(localized: "Monday to Friday") : String(localized: "\(setup.schoolDays.count) days a week")
        return String(localized: "\(session) · school \(start) to \(end), \(days)")
    }

    private static func time(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct SummaryRow<Detail: View>: View {
    let systemImage: String
    let title: String
    let edit: () -> Void
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: systemImage, foreground: Theme.primaryText.opacity(0.85), background: Color.white.opacity(0.1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                detail
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            Button("Edit", action: edit)
                .buttonStyle(.folioLink)
                .accessibilityLabel("Edit \(title)")
        }
        .padding(.vertical, 12)
        .frame(minHeight: 68)
    }
}

// MARK: Shared pieces

/// The open panels setup uses. Folio's sandbox can only reach folders the
/// student chooses, apart from Downloads.
enum HomeFolderPanel {
    enum Kind: CaseIterable {
        case desktop, documents

        /// The folder's name on disk.
        var folderName: String { self == .desktop ? "Desktop" : "Documents" }
        /// The folder's name as Finder shows it, in the student's language.
        var displayName: String { self == .desktop ? String(localized: "Desktop") : String(localized: "Documents") }

        init?(of url: URL) {
            guard let kind = Kind.allCases.first(where: { url.standardizedFileURL == HomeFolderPanel.home.appending(path: $0.folderName, directoryHint: .isDirectory).standardizedFileURL }) else { return nil }
            self = kind
        }
    }

    /// The student's real home folder: the sandbox's is Folio's container.
    static let home: URL = {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static func tildePath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let homePath = home.path(percentEncoded: false)
        return path.hasPrefix(homePath) ? "~/" + path.dropFirst(homePath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : path
    }

    /// Asks to let Folio watch the Desktop or Documents folder.
    static func allow(_ kind: Kind) -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "To watch your \(kind.displayName) folder, Folio needs your permission. Click Allow.")
        panel.prompt = String(localized: "Allow")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = home.appending(path: kind.folderName, directoryHint: .isDirectory)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolderToWatch() -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a folder for Folio to watch. Anything new that lands there is sorted.")
        panel.prompt = String(localized: "Watch Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = home
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Makes a Folio folder in Documents, after asking macOS to let Folio in.
    /// Choosing a different folder in the panel uses that folder instead.
    static func makeFolioFolder() -> URL? {
        let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
        let panel = NSOpenPanel()
        panel.message = String(localized: "Folio will keep your sorted files in a Folio folder in Documents. Click Allow to let it, or choose another folder.")
        panel.prompt = String(localized: "Allow")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = documents
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        guard chosen.standardizedFileURL == documents.standardizedFileURL else { return chosen }
        let folder = documents.appending(path: "Folio", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }
}

/// The open panel for choosing the School folder.
enum SchoolFolderPanel {
    static func choose(message: LocalizedStringResource = "Choose the folder that holds your subject folders, or make a new one.") -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: message)
        panel.prompt = String(localized: "Use This Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = HomeFolderPanel.home.appending(path: "Documents", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        return confirmed(chosen)
    }

    /// A whole home, Desktop, Documents or Downloads folder would mix subject
    /// folders in with everything else there, which is easy to choose by
    /// accident, so Folio offers to make a Folio folder inside it instead.
    private static func confirmed(_ chosen: URL) -> URL? {
        let home = HomeFolderPanel.home.standardizedFileURL
        let broad = [home] + ["Desktop", "Documents", "Downloads"].map { home.appending(path: $0, directoryHint: .isDirectory).standardizedFileURL }
        guard broad.contains(chosen.standardizedFileURL) else { return chosen }
        let name = FileManager.default.displayName(atPath: chosen.path(percentEncoded: false))
        let alert = NSAlert()
        alert.messageText = String(localized: "Use your whole “\(name)” folder?")
        alert.informativeText = String(localized: "Folio would add a folder for each subject straight into it. To keep your schoolwork together, Folio can make a Folio folder inside it instead.")
        alert.addButton(withTitle: String(localized: "Make a Folio Folder"))
        alert.addButton(withTitle: String(localized: "Use “\(name)”"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let folder = chosen.appending(path: "Folio", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return folder
            } catch {
                return nil
            }
        case .alertSecondButtonReturn:
            return chosen
        default:
            return nil
        }
    }
}

/// A university course: its code, its name and, when opened, what it covers.
private struct SubjectDraftRow: View {
    @Binding var draft: SetupModel.SubjectDraft
    var showsCode = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("Include \(draft.subject.name)", isOn: $draft.isIncluded)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                ColourDotPicker(colorHex: $draft.subject.colorHex)
                if showsCode {
                    TextField("Code", text: Binding(
                        get: { draft.subject.codes.first ?? "" },
                        set: { code in
                            let code = code.uppercased().filter { !$0.isWhitespace }
                            draft.subject.codes = code.isEmpty ? [] : [code]
                            if draft.subject.name.isEmpty || TimetableReader.code(in: draft.subject.name) != nil {
                                draft.subject.name = code
                            }
                        }
                    ), prompt: Text("Code"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium).monospaced())
                    .frame(width: 96)
                }
                TextField("Name", text: nameBinding, prompt: Text(namesCourse ? "Course name" : "Subject name"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($nameFocused)
                    .frame(maxWidth: 220)
                Spacer(minLength: 8)
                Button {
                    withAnimation(Theme.motion()) { draft.showsDetails.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(draft.showsDetails ? 180 : 0))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(draft.showsDetails ? "Hide details" : "Describe this course")
                .accessibilityLabel(draft.showsDetails ? "Hide details" : "Show details")
            }
            .opacity(draft.isIncluded ? 1 : 0.55)

            if draft.showsDetails {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("What it covers")
                                .foregroundStyle(Theme.secondaryText)
                                .gridColumnAlignment(.trailing)
                            TextField("What it covers", text: $draft.subject.summary, prompt: Text("e.g. Cells, genetics, ecology and the human body"), axis: .vertical)
                                .lineLimit(1...3)
                                .labelsHidden()
                        }
                        GridRow {
                            Text("Other names")
                                .foregroundStyle(Theme.secondaryText)
                            CommaListField(title: "Other names", prompt: "e.g. Bio, Biologie, SBI4U", items: $draft.subject.aliases)
                                .labelsHidden()
                        }
                    }
                    .font(.system(size: 13))
                }
                .textFieldStyle(.roundedBorder)
                .padding(.leading, 34)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 12)
        .onAppear {
            if draft.subject.name.isEmpty { nameFocused = true }
        }
    }

    /// At uni, a course is named by its code, which is also its folder's name,
    /// so the second field holds the course's title, such as "Mathematics 1A".
    private var namesCourse: Bool {
        showsCode && !draft.subject.codes.isEmpty && draft.subject.name == draft.subject.codes.first
    }

    private var nameBinding: Binding<String> {
        guard namesCourse else { return $draft.subject.name }
        return Binding(
            get: { draft.subject.summary },
            set: { title in
                // The title is also another name for the course, so it's found in files.
                let old = draft.subject.summary
                draft.subject.summary = title
                if !old.isEmpty, let index = draft.subject.aliases.firstIndex(of: old) {
                    if title.isEmpty {
                        draft.subject.aliases.remove(at: index)
                    } else {
                        draft.subject.aliases[index] = title
                    }
                } else if !title.isEmpty, !draft.subject.aliases.contains(title) {
                    draft.subject.aliases.append(title)
                }
            }
        )
    }
}

/// Shown when the settings are fine but Folio can't reach the School folder.
private struct RelinkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconTile(systemName: "folder.badge.questionmark", foreground: Theme.accent, background: Theme.accent.opacity(0.16), size: 56, cornerRadius: 16, symbolSize: 24)
            Text("Where's your \(model.libraryTitle)?")
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Folio can't reach your \(model.libraryTitle) any more. It may have been moved or renamed. Choose it again and Folio will carry on where it left off.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.primaryText.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose Folder…") {
                if let folder = SchoolFolderPanel.choose(message: "Choose your \(model.libraryTitle).") {
                    model.changeLibrary(to: folder)
                }
            }
            .buttonStyle(.folioPrimaryLarge)
            .padding(.top, 8)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
