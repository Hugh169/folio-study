import SwiftUI
import FolioKit

/// Folio's Settings window (⌘,).
struct SettingsView: View {
    enum Pane: Hashable {
        case subjects, folders, sorting, planner, background, ai
    }

    @Environment(AppModel.self) private var model
    @State private var pane: Pane

    /// - Parameter pane: The pane to open on, for previews.
    init(pane: Pane = .subjects) {
        _pane = State(initialValue: pane)
    }

    var body: some View {
        TabView(selection: $pane) {
            Tab("Subjects", systemImage: "books.vertical", value: .subjects) {
                SubjectsSettings()
            }
            Tab("Folders", systemImage: "folder", value: .folders) {
                FoldersSettings()
            }
            Tab("Sorting", systemImage: "arrow.triangle.branch", value: .sorting) {
                SortingSettings()
            }
            Tab("Planner", systemImage: "calendar", value: .planner) {
                PlannerSettings()
            }
            Tab("Background", systemImage: "menubar.arrow.up.rectangle", value: .background) {
                BackgroundSettings()
            }
            Tab("AI & Privacy", systemImage: "lock", value: Pane.ai) {
                AISettings()
            }
        }
        .frame(width: 700)
        .disabled(model.phase == .setup || model.hasDeletedEverything)
        .sheet(isPresented: Binding(get: { model.isShowingDeleteAll }, set: { model.isShowingDeleteAll = $0 })) {
            DeleteAllDataSheet()
                .environment(model)
        }
    }
}

// MARK: Subjects

private struct SubjectsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Subject.ID?
    @State private var removing: Subject?
    @State private var isStartingTerm = false
    /// The pack whose full course list is open.
    @State private var browsing: CurriculumPack?

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section(model.subjectsTitle) {
                        ForEach(model.subjects) { subject in
                            row(subject)
                                .contextMenu {
                                    Button("Archive") { model.archiveSubject(subject) }
                                }
                        }
                        .onMove { from, to in
                            var current = model.subjects
                            current.move(fromOffsets: from, toOffset: to)
                            model.profile.subjects = current + model.archivedSubjects
                        }
                    }
                    if !model.archivedSubjects.isEmpty {
                        Section("Past terms") {
                            ForEach(model.archivedSubjects) { subject in
                                row(subject)
                                    .foregroundStyle(.secondary)
                                    .contextMenu {
                                        Button("Restore") { model.restoreSubject(subject) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack(spacing: 0) {
                    Menu {
                        Button(model.newSubjectTitle) {
                            let subject = Subject(name: model.newSubjectTitle, colorHex: unusedSubjectColour(among: model.subjects))
                            model.profile.subjects.append(subject)
                            selection = subject.id
                        }
                        if let pack = model.pack, !pack.subjects.isEmpty {
                            Button("Add from the \(pack.name) List…") { browsing = pack }
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 28, height: 22)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a subject")
                    .accessibilityLabel(model.newSubjectTitle)
                    Button {
                        removing = model.subject(selection ?? UUID())
                    } label: {
                        Image(systemName: "minus").frame(width: 28, height: 22)
                    }
                    .help("Remove the selected subject")
                    .accessibilityLabel("Remove Subject")
                    .disabled(selection == nil || model.subjects.count <= 1)
                    Menu {
                        Button("Import Pack…") { model.chooseAndOpenPack() }
                        Button("Export Subjects as Pack…") { model.exportPack() }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 28, height: 22)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Share your subjects with a class, or add someone else's")
                    .accessibilityLabel("Share Subjects")
                    Spacer()
                    Button("New Term…") { isStartingTerm = true }
                        .help("Archive this term's subjects and add the next term's")
                        .padding(.trailing, 6)
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 220)

            Divider()

            if let index = model.profile.subjects.firstIndex(where: { $0.id == selection }) {
                SubjectEditor(
                    subject: $model.profile.subjects[index],
                    library: model.libraryURL,
                    existingFolder: model.subjectFolderURLs[model.profile.subjects[index].id]
                )
            } else {
                ContentUnavailableView("Choose a Subject", systemImage: "books.vertical", description: Text("Pick a subject to change its name, colour and how Folio recognises it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 520)
        .onAppear {
            selection = selection ?? model.subjects.first?.id
        }
        .sheet(isPresented: $isStartingTerm) {
            StartTermSheet()
        }
        .sheet(item: $browsing) { pack in
            CoursePicker(pack: pack, isChosen: model.isTaking, toggle: { model.add($0, from: pack) }, canUntick: false)
        }
        .confirmationDialog(
            Text(removing.map { String(localized: "Remove \($0.name)?") } ?? String(localized: "Remove this subject?")),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { subject in
            Button("Remove Subject", role: .destructive) {
                model.profile.subjects.removeAll { $0.id == subject.id }
                selection = model.subjects.first?.id
            }
        } message: { subject in
            Text("Its folder and files stay where they are. Folio just stops filing into \(subject.name).")
        }
    }

    private func row(_ subject: Subject) -> some View {
        HStack(spacing: 8) {
            SubjectDot(color: subject.color)
            Text(subject.name.isEmpty ? String(localized: "Untitled") : subject.name)
            if let term = subject.term, subject.isArchived {
                Spacer()
                Text(term)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .tag(subject.id)
    }
}

/// Archives this term's subjects and adds the next term's, from the timetable when it can.
struct StartTermSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var archivesCurrent = true
    @State private var courses: [TimetableReader.Course] = []
    @State private var chosen: Set<String> = []
    /// The term just archived, to look back on before closing.
    @State private var finished: TermRequest?

    var body: some View {
        if let finished {
            VStack(alignment: .leading, spacing: 16) {
                Text("How \(finished.title) went")
                    .font(.system(size: 17, weight: .semibold))
                ScrollView {
                    TermSummaryView(summary: model.termSummary(finished))
                }
                Text("It stays under Progress, in Past terms.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 600, height: 520)
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start a New Term")
                .font(.system(size: 17, weight: .semibold))
            Text("Folio files into the new term's subjects. Last term's folders and files stay where they are, under Past terms.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("New term", text: $name, prompt: Text(verbatim: model.suggestedTermName))
                Toggle("Archive this term's \(model.subjects.count) subjects", isOn: $archivesCurrent)
            }
            .formStyle(.columns)

            VStack(alignment: .leading, spacing: 8) {
                Text("Courses in your timetable")
                    .font(.system(size: 13, weight: .semibold))
                if courses.isEmpty {
                    Text(model.isCalendarConnected
                        ? "No new course codes in your calendar over the next four weeks. You can add subjects yourself afterwards."
                        : "Connect your calendar in the Planner pane to add courses from your timetable.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(courses) { course in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(course.code) },
                            set: { if $0 { chosen.insert(course.code) } else { chosen.remove(course.code) } }
                        )) {
                            HStack(spacing: 6) {
                                Text(course.code).font(.system(size: 13, weight: .medium).monospaced())
                                if let name = course.name {
                                    Text(name).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Term") {
                    let leaving = model.subjects
                    let terms = Set(leaving.compactMap(\.term))
                    model.startNewTerm(
                        named: name.trimmingCharacters(in: .whitespaces),
                        archivesCurrent: archivesCurrent,
                        courses: courses.filter { chosen.contains($0.code) }
                    )
                    if archivesCurrent && !leaving.isEmpty {
                        let title = (terms.count == 1 ? terms.first : nil) ?? String(localized: "last term")
                        withAnimation(Theme.motion()) { finished = TermRequest(title: title, subjectIDs: leaving.map(\.id)) }
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if name.isEmpty { name = model.suggestedTermName }
            let current = Set(model.subjects.flatMap { $0.codes + [$0.name] }.map { $0.uppercased() })
            courses = model.coursesInCalendar().courses.filter { !current.contains($0.code) }
            chosen = Set(courses.map(\.code))
        }
    }
}

private struct SubjectEditor: View {
    @Binding var subject: Subject
    let library: URL?
    /// The subject's folder as Folio last found it.
    let existingFolder: URL?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: name)
                LabeledContent("Colour") {
                    ColourDotPicker(colorHex: $subject.colorHex)
                }
                TextField("Folder", text: Binding(
                    get: { subject.folderName ?? "" },
                    set: { subject.folderName = $0.isEmpty ? nil : $0 }
                ), prompt: Text(subject.name))
                TextField("Term", text: Binding(
                    get: { subject.term ?? "" },
                    set: { subject.term = $0.isEmpty ? nil : $0 }
                ), prompt: Text("e.g. 2027 Semester 1"))
                CommaListField(title: "Teachers", prompt: "e.g. Ms Nguyen", items: $subject.teachers)
            } footer: {
                Text("Files go in \(library?.lastPathComponent ?? "School") › \(subject.effectiveFolderName).")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("What it covers", text: $subject.summary, prompt: Text("e.g. Cells, genetics, ecology and the human body"), axis: .vertical)
                    .lineLimit(2...4)
                CommaListField(title: "Other names", prompt: "e.g. Bio, Biologie", items: $subject.aliases)
                CommaListField(title: "Course codes", prompt: "e.g. SBI4U, 8461", items: $subject.codes)
                CommaListField(title: "Topic words", prompt: "e.g. photosynthesis, mitosis", items: $subject.keywords)
            } header: {
                Text("Recognising its files")
            } footer: {
                Text("Folio's on-device AI reads the description. Other names, course codes and topic words are looked for in each file; names and codes count most.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(subject.id)
    }

    /// Renaming a subject keeps using its existing folder, so its files aren't
    /// left behind. The Folder field shows the folder it keeps using.
    private var name: Binding<String> {
        Binding(
            get: { subject.name },
            set: { newName in
                if subject.folderName == nil, let existingFolder {
                    subject.folderName = existingFolder.lastPathComponent
                }
                subject.name = newName
            }
        )
    }
}

// MARK: Folders

private struct FoldersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var customTemplate = ""

    private static let presets = SetupModel.layouts

    var body: some View {
        @Bindable var model = model
        Form {
            Section("School folder") {
                LabeledContent("Folder") {
                    Text(model.libraryURL?.path(percentEncoded: false).replacingOccurrences(of: realHome, with: "~") ?? String(localized: "No folder chosen"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { model.open(model.libraryURL) }
                        .disabled(model.libraryURL == nil)
                    Button("Change…") {
                        if let folder = SchoolFolderPanel.choose(message: "Choose the folder Folio should file into.") {
                            model.changeLibrary(to: folder)
                        }
                    }
                }
            }

            Section {
                Picker("Arrange files by", selection: $model.profile.folderTemplate) {
                    ForEach(Self.presets) { layout in
                        Text(layout.title).tag(layout.template)
                    }
                    if !Self.presets.contains(where: { $0.template == model.profile.folderTemplate }) {
                        Text("Custom").tag(model.profile.folderTemplate)
                    }
                }
                LabeledContent("Custom layout") {
                    TextField("Custom layout", text: $customTemplate, prompt: Text("{subject}/{year}/{type}"))
                        .labelsHidden()
                        .onSubmit(applyCustomTemplate)
                        .frame(maxWidth: 260)
                    Button("Use", action: applyCustomTemplate)
                        .disabled(customTemplate.isEmpty || FolderTemplate(customTemplate).problem != nil)
                }
                if let problem = FolderTemplate(customTemplate).problem, !customTemplate.isEmpty {
                    Text(Self.describe(problem))
                        .foregroundStyle(Theme.warning)
                }
                LabeledContent("Example") {
                    Text(example)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } header: {
                Text("Folder layout")
            } footer: {
                Text("Use {subject}, {type}, {year} and {exam}, with a / between folders. Folders for details Folio can't find are left out. Files already filed stay where they are.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($model.profile.documentTypes, id: \.name) { $type in
                    CommaListField(verbatimTitle: type.name, prompt: "Words that identify it", items: $type.aliases)
                }
                Picker("When Folio can't tell", selection: Binding(
                    get: { model.profile.defaultDocumentType ?? "" },
                    set: { model.profile.defaultDocumentType = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Leave it in the subject folder").tag("")
                    ForEach(model.profile.documentTypes, id: \.name) { type in
                        Text(type.name).tag(type.name)
                    }
                }
            } header: {
                Text("Kinds of document")
            } footer: {
                Text("Each kind's name is also its folder's name. Folio looks for these words in a file's name and first lines.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onAppear {
            if !Self.presets.contains(where: { $0.template == model.profile.folderTemplate }) {
                customTemplate = model.profile.folderTemplate
            }
        }
    }

    private var example: String {
        let subject = model.subjects.first ?? Subject(name: "History", colorHex: 0)
        let folders = FolderTemplate(model.profile.folderTemplate).folders(for: subject, facets: Facets(documentType: "Past Papers", year: 2023, exam: "HSC"))
        return ([model.libraryURL?.lastPathComponent ?? "School"] + folders + ["2023 paper.pdf"]).joined(separator: " › ")
    }

    private func applyCustomTemplate() {
        let template = FolderTemplate(customTemplate)
        guard !customTemplate.isEmpty, template.problem == nil else { return }
        model.profile.folderTemplate = template.parts.joined(separator: "/")
    }

    private var realHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    static func describe(_ problem: FolderTemplate.Problem) -> String {
        switch problem {
        case .noSubjectFolder: String(localized: "The layout needs a {subject} folder.", comment: "Keep {subject} as it is: it's typed into the layout")
        case .subjectNotOnItsOwn: String(localized: "{subject} needs to be a folder of its own, used once.", comment: "Keep {subject} as it is: it's typed into the layout")
        case .unknownPlaceholder(let name): String(localized: "Folio doesn't know {\(name)}. Use {subject}, {type}, {year} or {exam}.", comment: "Keep the words in braces as they are: they're typed into the layout")
        case .invalidFolder(let name): String(localized: "“\(name)” can't be a folder name.")
        }
    }
}

// MARK: Sorting

private struct SortingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("File on its own", selection: $model.profile.autoFileLevel) {
                    ForEach(AutoFileLevel.allCases, id: \.self) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(of: level))
                            Text(Self.explanation(of: level))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("How sure should Folio be?")
            } footer: {
                Text("Anything Folio isn't sure about waits under Needs a look, and every file it moves can be put back with Undo.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($model.profile.rules) { $rule in
                    RuleRow(rule: $rule) {
                        model.profile.rules.removeAll { $0.id == rule.id }
                    }
                }
                Button("Add Rule") {
                    guard let subject = model.subjects.first else { return }
                    model.profile.rules.append(SortingRule(field: .fileName, contains: "", subjectID: subject.id))
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("A rule always wins. Use them for course codes in file names, or the website a teacher shares files from.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    static func title(of level: AutoFileLevel) -> String {
        switch level {
        case .careful: String(localized: "Careful (recommended)")
        case .balanced: String(localized: "Balanced")
        case .eager: String(localized: "Eager")
        }
    }

    static func explanation(of level: AutoFileLevel) -> String {
        switch level {
        case .careful: String(localized: "Only when separate signals agree, such as the words in the file and the on-device AI.")
        case .balanced: String(localized: "Also when the file clearly names its subject and nothing disagrees.")
        case .eager: String(localized: "Whenever one subject is clearly ahead. Fewer questions, more mistakes.")
        }
    }
}

private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: SortingRule
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Where", selection: $rule.field) {
                Text("File name").tag(SortingRule.Field.fileName)
                Text("Web address").tag(SortingRule.Field.sourceURL)
                Text("Folder it came from").tag(SortingRule.Field.sourceFolder)
            }
            .labelsHidden()
            .fixedSize()
            Text("contains")
                .foregroundStyle(.secondary)
            TextField("Text", text: $rule.contains, prompt: Text("MATH1131"))
                .labelsHidden()
                .frame(minWidth: 90)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityLabel("files into")
            Picker("Subject", selection: $rule.subjectID) {
                ForEach(model.subjects) { subject in
                    Text(subject.name).tag(subject.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Kind", selection: $rule.documentType) {
                Text("Any kind").tag(String?.none)
                ForEach(model.profile.documentTypes, id: \.name) { type in
                    Text(type.name).tag(Optional(type.name))
                }
            }
            .labelsHidden()
            .fixedSize()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this rule")
            .accessibilityLabel("Remove Rule")
        }
    }
}

// MARK: Planner

private struct PlannerSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editingTimetable = false
    @State private var playsTimerSound = true
    @State private var remindsWeeklyReview = false

    var body: some View {
        @Bindable var model = model
        Form {
            CalendarSection()

            Section {
                if let timetable = model.profile.timetable {
                    LabeledContent("Timetable") {
                        Text(timetable.summary)
                            .foregroundStyle(.secondary)
                        Button("Edit…") { editingTimetable = true }
                    }
                } else {
                    Toggle("I have school hours", isOn: Binding(
                        get: { model.profile.studyPreferences.schoolHours != nil },
                        set: { model.profile.studyPreferences.schoolHours = $0 ? SchoolHours() : nil }
                    ))
                    if let hours = model.profile.studyPreferences.schoolHours {
                        LabeledContent("From") {
                            MinutePicker(minutes: Binding(
                                get: { hours.start },
                                set: { model.profile.studyPreferences.schoolHours?.start = $0 }
                            ))
                            Text("to")
                            MinutePicker(minutes: Binding(
                                get: { hours.end },
                                set: { model.profile.studyPreferences.schoolHours?.end = $0 }
                            ))
                        }
                    }
                    LabeledContent("Timetable") {
                        Button("Set Up Timetable…") { editingTimetable = true }
                            .disabled(model.subjects.isEmpty)
                    }
                }
            } header: {
                Text("School")
            } footer: {
                Text(model.profile.timetable == nil
                    ? "School hours are kept free on weekdays and shown in the planner. With your timetable, Folio also shows your classes and notices files that arrive during a lesson."
                    : "Your timetable sets your school days. With term dates, the holidays are free for study.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Add assessments to Reminders", isOn: Binding(
                    get: { model.usesReminders },
                    set: { on in Task { await model.setUsesReminders(on) } }
                ))
                .disabled(model.live == nil)
                if model.remindersAccessRefused {
                    PrivacyRefusedNote(service: String(localized: "Reminders"), anchor: "Privacy_Reminders")
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Assessments go in a Folio list in Apple Reminders, with alerts the day before and two hours before, so they reach your iPhone. Ticking one off there marks it submitted here.")
                    .foregroundStyle(.secondary)
            }

            Section {
                WindowList(title: "Weekdays", windows: $model.profile.studyPreferences.weekdayWindows)
                WindowList(title: "Weekends", windows: $model.profile.studyPreferences.weekendWindows)
                Stepper("Sessions last \(model.profile.studyPreferences.sessionMinutes) minutes", value: $model.profile.studyPreferences.sessionMinutes, in: 30...180, step: 15)
                Stepper("Assessment sessions last \(model.profile.studyPreferences.longSessionMinutes) minutes", value: $model.profile.studyPreferences.longSessionMinutes, in: 30...240, step: 15)
                Stepper("At most \(model.profile.studyPreferences.maxSessionsPerDay) sessions a day", value: $model.profile.studyPreferences.maxSessionsPerDay, in: 1...8)
                Stepper("\(model.profile.studyPreferences.breakMinutes) minute break between sessions", value: $model.profile.studyPreferences.breakMinutes, in: 0...90, step: 5)
            } header: {
                Text("When you study")
            } footer: {
                Text("Plan My Week puts sessions in these times, around your classes, events and exams. Work for each assessment is spread over the weeks before it's due.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play a sound when time's up", isOn: $playsTimerSound)
                    .onChange(of: playsTimerSound) { model.playsTimerSound = playsTimerSound }
            } header: {
                Text("Study timer")
            } footer: {
                Text("The timer records the minutes you actually study, so Plan My Week knows how much is left for each assessment.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Remind me on Sunday evening", isOn: $remindsWeeklyReview)
                    .onChange(of: remindsWeeklyReview) { model.remindsWeeklyReview = remindsWeeklyReview }
            } header: {
                Text("Weekly review")
            } footer: {
                Text("A notification at 6 pm on Sundays to look back on your week and plan the next one. The review is also on Today from Sunday afternoon.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 780)
        .onAppear {
            playsTimerSound = model.playsTimerSound
            remindsWeeklyReview = model.remindsWeeklyReview
        }
        .sheet(isPresented: $editingTimetable) {
            TimetableEditor(
                timetable: model.profile.timetable ?? model.newTimetable(),
                subjects: model.subjects,
                weekdays: model.profile.studyPreferences.schoolHours?.weekdays ?? SchoolHours().weekdays,
                calendar: model.calendar,
                onSave: { model.profile.timetable = $0 },
                onRemove: model.profile.timetable == nil ? nil : { model.profile.timetable = nil }
            )
        }
    }
}

/// Connects Apple Calendar, and chooses which calendars Folio plans around.
private struct CalendarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            if model.isCalendarConnected {
                ForEach(model.calendarList) { info in
                    HStack(spacing: 10) {
                        Circle().fill(Color(hex: info.colorHex)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.title)
                            Text(info.account)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Timetable", isOn: Binding(
                            get: { model.timetableCalendarIDs.contains(info.id) },
                            set: { model.setTimetable(info, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Your class timetable. Folio suggests subjects from it and notices files downloaded during class.")
                        Toggle("Plan around", isOn: Binding(
                            get: { model.plannedCalendarIDs.contains(info.id) },
                            set: { model.setPlansAround(info, $0) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                Stepper("Keep \(model.profile.studyPreferences.bufferMinutes) minutes free around events", value: $model.profile.studyPreferences.bufferMinutes, in: 0...90, step: 5)
            } else {
                HStack {
                    Text("Folio can plan your study around your classes, work and plans.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect Apple Calendar…") {
                        Task { await model.connectCalendar() }
                    }
                    .disabled(model.live == nil)
                }
                if model.calendarAccessRefused {
                    PrivacyRefusedNote(service: String(localized: "Calendars"), anchor: "Privacy_Calendars")
                }
            }
        } header: {
            Text("Apple Calendar")
        } footer: {
            Text("Folio reads your calendars on this Mac and never changes them. Study sessions stay in Folio.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Study windows for weekdays or weekends: from-to rows that can be added and removed.
private struct WindowList: View {
    let title: LocalizedStringKey
    @Binding var windows: [StudyPreferences.Window]

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(windows.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        MinutePicker(minutes: $windows[index].start)
                        Text("to")
                            .foregroundStyle(.secondary)
                        MinutePicker(minutes: $windows[index].end)
                        Button {
                            windows.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this time")
                        .accessibilityLabel("Remove Time")
                    }
                }
                Button("Add Time") {
                    let start = (windows.last?.end ?? 15 * 60) + 30
                    windows.append(StudyPreferences.Window(start: min(start, 22 * 60), end: min(start + 120, 23 * 60)))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// A time of day, stored as minutes after midnight.
/// A time of day as minutes after midnight, such as 525 for 8:45 am.
struct MinutePicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("Time", selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .fixedSize()
    }
}

/// Explains how to allow access after the student said no.
private struct PrivacyRefusedNote: View {
    let service: String
    let anchor: String

    var body: some View {
        HStack {
            Text("Folio isn't allowed to use \(service). You can change that in System Settings.")
                .foregroundStyle(Theme.warning)
            Spacer()
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: Background

private struct BackgroundSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.watchedFolders) { folder in
                    WatchedFolderRow(folder: folder)
                }
                Button("Watch Another Folder…") { model.addWatchedFolder() }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("New files that arrive in these folders are sorted at your sorting level. Files that don't look like schoolwork stay where they are, and files already in a folder are only sorted if you ask.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Folio at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            } header: {
                Text("While you work")
            } footer: {
                Text("Closing Folio's window keeps it sorting from the menu bar. Quit it from the menu bar to stop.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Notifications") {
                    switch model.notificationsAllowed {
                    case .some(true):
                        Text("On")
                    case .some(false):
                        Button("Turn On in System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    case .none:
                        Text("Folio asks when you first watch a folder")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Folio only tells you about files it sorted in the background, never ones you dropped yourself. Each notification has Undo.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .task { await model.refreshNotificationStatus() }
    }
}

private struct WatchedFolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: WatchedFolder
    @State private var existing: [URL] = []
    @State private var confirmingSort = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.isDownloads ? "arrow.down.circle" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                Text(folder.path.replacingOccurrences(of: realHome, with: "~"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if folder.isOn && !existing.isEmpty {
                Button("Sort Existing Files…") { confirmingSort = true }
                    .help("Sort the \(fileCountText(existing.count)) already in \(folder.displayName)")
            }
            if !folder.isDownloads {
                Button {
                    model.removeWatchedFolder(folder)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop watching this folder")
                .accessibilityLabel("Stop Watching \(folder.displayName)")
            }
            Toggle("Watch \(folder.displayName)", isOn: Binding(get: { folder.isOn }, set: { model.setWatching(folder, on: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .task(id: folder.isOn) {
            existing = folder.isOn ? model.existingFiles(in: folder) : []
        }
        .confirmationDialog("Sort the \(fileCountText(existing.count)) already in \(folder.displayName)?", isPresented: $confirmingSort) {
            Button("Sort Them") {
                model.sortFilesAlreadyIn(folder)
                existing = []
            }
        } message: {
            Text("Schoolwork Folio is sure about is filed, anything it isn't sure about waits under Needs a look, and the rest stays where it is.")
        }
    }

    private var realHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }
}

// MARK: AI & Privacy

private struct AISettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Use Apple Intelligence to read files", isOn: $model.usesOnDeviceAI)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.aiNotice == nil ? Theme.success : Theme.warning)
                            .frame(width: 8, height: 8)
                        Text(model.aiNotice == nil ? String(localized: "Ready") : statusText)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("On-device AI")
            } footer: {
                Text("Apple's on-device model reads the start of each file, on this Mac. When it's off or unavailable, Folio sorts with keywords and your past choices, and asks more often.")
                    .foregroundStyle(.secondary)
            }

            ClaudeSection()

            Section {
                Toggle("Ask Apple's cloud AI about hard files", isOn: .constant(false))
                    .disabled(true)
            } header: {
                Text("Private Cloud Compute")
            } footer: {
                Text("Coming in a later version, and only for files the on-device AI can't decide. Private Cloud Compute is built so that what it reads isn't stored and can't be seen by Apple.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Learned from", value: fileCountText(model.learnedExampleCount))
                HStack {
                    Spacer()
                    Button("Learn From My Folders Again") { model.learnFromLibrary() }
                        .disabled(model.learningProgress != nil || model.libraryURL == nil)
                    Button("Forget What Folio Learned…") { confirmingForget = true }
                        .disabled(model.learnedExampleCount == 0)
                }
            } header: {
                Text("Learning")
            } footer: {
                Text("Folio learns from the subjects you choose under Needs a look, the files you put back and refile, and the files already in your subject folders.")
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text(privacyText)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete All Data")
                        Text("Removes everything Folio keeps on this Mac, then quits, as if it had never been installed.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete All Data…") { model.isShowingDeleteAll = true }
                        .shotTarget("delete-all-data")
                }
            } footer: {
                Text("Your School folder and the files in it stay where they are.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 760)
        .onAppear { model.refreshClaudeUsage() }
        .confirmationDialog("Forget what Folio has learned?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { model.forgetLearning() }
        } message: {
            Text("Your files stay where they are. Folio will ask more often until it learns your files again.")
        }
    }

    private var statusText: String {
        model.aiUnavailableReason ?? String(localized: "Unavailable")
    }

    private var privacyText: String {
        let reading = model.usesClaude
            ? String(localized: "Folio reads your files on this Mac. Only the short excerpts described under Claude leave it, for files Folio can't decide.")
            : String(localized: "Folio reads your files only on this Mac and never uploads them.")
        let records = String(localized: "Its records of what it filed, where things came from and what it learned stay in Folio's own folder on this Mac.")
        return reading + " " + records
    }
}

/// Claude Haiku with the student's own API key, for files Folio can't decide.
private struct ClaudeSection: View {
    @Environment(AppModel.self) private var model
    @State private var draftKey = ""
    @State private var confirmingRemove = false

    var body: some View {
        Section {
            Toggle("Ask Claude about files Folio can't decide", isOn: Binding(get: { model.usesClaude }, set: { model.setUsesClaude($0) }))
                .disabled(!model.hasClaudeKey)
            Toggle("Include photos with almost no text", isOn: Binding(get: { model.claudeSeesPhotos }, set: { model.setClaudeSeesPhotos($0) }))
                .disabled(!model.usesClaude)
            if model.hasClaudeKey {
                LabeledContent("API key", value: "Saved in your keychain")
                HStack {
                    Spacer()
                    Button("Test Key") { Task { await model.testClaudeKey() } }
                        .disabled(model.claudeStatus == .checking)
                    Button("Remove Key…") { confirmingRemove = true }
                }
            } else {
                LabeledContent("API key") {
                    HStack {
                        SecureField("API key", text: $draftKey, prompt: Text(verbatim: "sk-ant-…"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            LabeledContent("Status") {
                status
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("This month", value: usageText)
        } header: {
            Text("Claude, with your own API key")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    Text("With a key, Make Flashcards can use Claude as often as you like. Folio sends the whole file's text, and Claude writes a card for each important idea in it, usually for well under a US cent a file.")
                    Text("With the switch above on, Folio also asks Claude about files it can't decide by itself. It sends what the on-device AI reads: up to 1,500 characters of the file's text, its title, the website it came from, and its name when there's little text. Photos go only if you include them. This can include files from watched folders such as Downloads.")
                    Text("Anthropic doesn't train its models on this and normally deletes it within 30 days. Requests are charged to your Anthropic account, so Folio doesn't limit them. Anthropic accounts are for adults, so if you're under 18, a parent should hold the account and the key.")
                }
                .foregroundStyle(.secondary)
                if !model.hasClaudeKey {
                    Link("Get a key in the Claude Console", destination: URL(string: "https://platform.claude.com")!)
                        .foregroundStyle(.tint)
                }
            }
        }
        .confirmationDialog("Remove your Claude API key?", isPresented: $confirmingRemove) {
            Button("Remove Key", role: .destructive) { model.removeClaudeKey() }
        } message: {
            Text("Folio will stop asking Claude. The key keeps working elsewhere until you delete it in the Claude Console.")
        }
    }

    @ViewBuilder private var status: some View {
        if !model.hasClaudeKey {
            dot(Theme.secondaryText, Text("Add your API key to use Claude"))
        } else {
            switch model.claudeStatus {
            case .unchecked:
                dot(Theme.secondaryText, Text("Not checked yet"))
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                }
            case .ready:
                dot(Theme.success, Text("Ready"))
            case .problem(let message):
                dot(Theme.warning, Text(verbatim: message))
            }
        }
    }

    private func dot(_ colour: Color, _ text: Text) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colour)
                .frame(width: 8, height: 8)
            text
        }
    }

    private var usageText: String {
        let usage = model.claudeUsage
        guard usage.requests > 0 else { return String(localized: "Nothing yet") }
        let cost = usage.cost < 0.01
            ? String(localized: "under US$0.01")
            : String(localized: "about \(usage.cost.formatted(.currency(code: "USD")))")
        return "\(String(localized: "\(usage.requests) requests")), \(cost)"
    }

    private func saveKey() {
        let key = draftKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draftKey = ""
        Task { await model.saveClaudeKey(key) }
    }
}
