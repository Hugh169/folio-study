#if DEBUG
import AppKit
import FolioKit
import Foundation

/// Drives the real app, sandbox and all, without showing a window:
///
///     Folio.app/Contents/MacOS/Folio -FolioSelfTest <folder> [-FolioSelfTestPhase restart|delete]
///
/// `<folder>` must be inside Folio's container, which is all the sandbox lets
/// it reach without the student choosing files. The first run sets Folio up
/// with `<folder>/School`, sorts everything in `<folder>/Drop`, puts the first
/// filed file back, files the first waiting file, watches `<folder>/Watched`
/// while the files in `<folder>/Arrivals` are moved into it, sorts
/// `<folder>/Shortcut` as a Shortcut would, plans next week around made-up
/// calendar events, tries the study tools (search, flashcards, a summary, the
/// timer and a past paper), and writes `report.json`. The restart run reopens
/// the same records and writes `report-restart.json`. The delete run reopens
/// them, deletes everything as Settings › Delete All Data does, and writes
/// `report-delete.json` with what's left. It never touches Calendar, Reminders,
/// notifications or the keychain, so macOS never asks for permission.
/// Debug builds only.
enum SelfTest {
    static var folder: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-FolioSelfTest"), index + 1 < arguments.count else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    private static var isRestart: Bool {
        UserDefaults.standard.string(forKey: "FolioSelfTestPhase") == "restart"
    }

    private static var isDelete: Bool {
        UserDefaults.standard.string(forKey: "FolioSelfTestPhase") == "delete"
    }

    private static let defaultsSuite = "FolioSelfTest"

    static func makeModel(in folder: URL) -> AppModel {
        let support = folder.appending(path: "Support", directoryHint: .isDirectory)
        if !isRestart && !isDelete {
            UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: support)
        }
        let model = AppModel.live(supportFolder: support, defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard, defaultsName: defaultsSuite, readsCalendar: false, usesKeychain: false)
        // Never ask for notification permission from a test run: the prompt would
        // appear on screen, and macOS would remember the answer for the real app.
        model.live?.askedForNotifications = true
        return model
    }

    static func run(_ model: AppModel, in folder: URL) async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var report: [String: Any] = ["phaseAtLaunch": name(of: model.phase), "screenAtLaunch": String(describing: model.destination)]

        if isDelete {
            await checkDeleteAll(model, in: folder, report: report)
        }

        if isRestart {
            await model.refreshLibrary()
            report["state"] = state(of: model)
            report["planner"] = [
                "sessions": model.sessions.count,
                "ownSessions": model.sessions.filter(\.isOwn).count,
                "plannedSteps": model.sessions.flatMap(\.plan).map { "\($0.title)\($0.isDone ? " ✓" : "")" },
                "todos": model.todos.map { "\($0.title)\($0.isDone ? " ✓" : "")" },
                "startingEarlier": model.assessments.filter { $0.planFrom != nil }.map(\.title),
                "markedWithADate": model.assessments.filter { $0.mark != nil && $0.markedAt != nil }.map(\.title),
                "assessments": model.assessments.map { "\($0.title) (\($0.kind.rawValue), \($0.status.rawValue)), due \($0.due.formatted(date: .abbreviated, time: .shortened))" },
                "linkedFiles": model.assessments.flatMap { model.linkedFiles(of: $0).map(\.name) },
            ]
            report["timetable"] = model.profile.timetable?.summary ?? "none"
            model.rebuildSearch()
            report["study"] = [
                "flashcards": model.flashcards.count,
                "practice": model.practiceAttempts.map { "\($0.paperName): \($0.mark?.text ?? "no mark")" },
                "recordedSessions": model.sessions.filter(\.isRecorded).map { "\($0.outcome?.rawValue ?? "?") \($0.doneMinutes ?? 0) min" },
                "indexedFiles": model.live?.store.indexedFiles().count ?? 0,
                "search": await model.searchFiles("electromagnetic induction").prefix(3).map(\.file.name),
            ]
            finish(report, at: folder.appending(path: "report-restart.json"))
        }

        let library = folder.appending(path: "School", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        model.finishSetup(library: library, subjects: Profile.starter().subjects, folderTemplate: "{subject}/{type}", learnsFromExistingFiles: false)
        report["phaseAfterSetup"] = name(of: model.phase)

        let drop = folder.appending(path: "Drop", directoryHint: .isDirectory)
        let files = ((try? FileManager.default.contentsOfDirectory(at: drop, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let clock = ContinuousClock()
        let start = clock.now
        model.addFiles(files)
        await waitUntil(seconds: 900) { model.sorting.allSatisfy(\.isDone) }
        report["sortingSeconds"] = (clock.now - start).components.seconds
        await model.refreshLibrary()
        report["afterSorting"] = state(of: model)

        // Put back the first filed file: it should return to Drop and wait under Needs a look.
        if let first = model.recentlySorted.first {
            model.undo(first)
            await waitUntil(seconds: 30) { !model.recentlySorted.contains { $0.id == first.id } }
            report["putBack"] = first.name
        }
        // File the first file that was waiting, in its first suggestion.
        if let waiting = model.needsReview.first, let subject = waiting.suggestions.first ?? model.subjects.first?.id {
            model.file(waiting, in: subject)
            await waitUntil(seconds: 30) { !model.needsReview.contains { $0.id == waiting.id } }
            report["filedFromNeedsALook"] = "\(waiting.name) → \(model.subject(subject)?.name ?? "?")"
        }
        await model.refreshLibrary()
        report["afterActions"] = state(of: model)

        // A watched folder: a file that lands in it should be sorted on its own.
        let watched = folder.appending(path: "Watched", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        await model.addWatchedFolder(watched)
        let arrivals = folder.appending(path: "Arrivals", directoryHint: .isDirectory)
        let arriving = ((try? FileManager.default.contentsOfDirectory(at: arrivals, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        try? await Task.sleep(for: .seconds(1))
        for file in arriving {
            try? FileManager.default.moveItem(at: file, to: watched.appending(path: file.lastPathComponent))
        }
        let names = Set(arriving.map(\.lastPathComponent))
        // Only background sorting records outcomes, so one per arrival means they're all done.
        await waitUntil(seconds: 180) {
            (model.live?.outcomes.count ?? 0) >= names.count && model.backgroundSorting.isEmpty
        }
        report["watched"] = [
            "arrived": Array(names).sorted(),
            "stillInWatchedFolder": relativePaths(in: watched),
            "recentlySorted": model.recentlySorted.prefix(4).map { "\($0.name) → \(model.location(of: $0.subjectID, folder: $0.folder))" },
        ]

        // A Shortcut: sort a file and describe what happened.
        let shortcutFiles = ((try? FileManager.default.contentsOfDirectory(at: folder.appending(path: "Shortcut"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        if !shortcutFiles.isEmpty {
            report["shortcutSummary"] = await model.sortForShortcut(shortcutFiles)
        }

        report["setup"] = checkSetup()
        report["assessmentFromFile"] = await checkAssessmentFromFile(model, in: folder)
        report["planner"] = checkPlanner(model)
        report["plans"] = checkPlans(model)
        report["progress"] = checkProgress(model)
        report["today"] = checkToday(model)
        report["timetable"] = await checkTimetable(model)
        report["study"] = await checkStudy(model)
        report["backup"] = checkBackup(model, in: folder)
        report["claude"] = ["hasKey": model.hasClaudeKey, "isOn": model.usesClaude, "keychain": checkKeychain()]
        report["filesInSchool"] = relativePaths(in: library)
        report["filesInDrop"] = relativePaths(in: drop)
        finish(report, at: folder.appending(path: "report.json"))
    }

    /// Deletes everything, as Settings › Delete All Data does, and reports
    /// what's left: no records or settings, but every file in the School folder.
    private static func checkDeleteAll(_ model: AppModel, in folder: URL, report: [String: Any]) async -> Never {
        var report = report
        await model.refreshLibrary()
        let support = folder.appending(path: "Support", directoryHint: .isDirectory)
        let library = folder.appending(path: "School", directoryHint: .isDirectory)
        let settings = UserDefaults(suiteName: defaultsSuite)
        report["before"] = [
            "subjects": model.subjects.count,
            "assessments": model.assessments.count,
            "sessions": model.sessions.count,
            "flashcards": model.flashcards.count,
            "timetable": model.profile.timetable != nil,
            "supportFiles": relativePaths(in: support),
            "settings": settings?.persistentDomain(forName: defaultsSuite)?.count ?? 0,
            "filesInSchool": relativePaths(in: library).count,
        ]
        let deletion = await model.deleteAllData(removingReminders: true)
        report["after"] = [
            "problems": deletion.problems,
            "supportFolderExists": FileManager.default.fileExists(atPath: support.path(percentEncoded: false)),
            "settings": settings?.persistentDomain(forName: defaultsSuite)?.count ?? 0,
            "filesInSchool": relativePaths(in: library).count,
            "recordsOpen": model.live != nil,
            "hasDeletedEverything": model.hasDeletedEverything,
            "flashcards": model.flashcards.count,
        ]
        // A fresh start on the same folders, as when Folio is opened again.
        let reopened = AppModel.live(supportFolder: support, defaults: settings ?? .standard, defaultsName: defaultsSuite, readsCalendar: false, usesKeychain: false)
        report["reopened"] = [
            "phase": name(of: reopened.phase),
            "subjects": reopened.profile.subjects.map(\.name),
            "assessments": reopened.assessments.count,
            "flashcards": reopened.flashcards.count,
        ]
        finish(report, at: folder.appending(path: "report-delete.json"))
    }

    /// Builds settings the way the setup screens do, without showing them:
    /// the HSC pack, a subject typed in, and a week of study times.
    private static func checkSetup() -> [String: Any] {
        guard let hsc = PackLibrary.pack("au-nsw-hsc") else { return ["error": "The HSC pack didn't load"] }
        let setup = SetupModel()
        setup.choose(hsc)
        setup.addOwn(named: "Bio")
        setup.addOwn(named: "Robotics")
        setup.studyTimes = [.evenings, .weekends]
        setup.sessionMinutes = 45
        setup.studentName = "Sam"
        let profile = setup.makeProfile()
        return [
            "packs": PackLibrary.packs.count,
            "pack": profile.packID ?? "",
            "subjects": profile.subjects.map(\.name),
            "distinctColours": Set(profile.subjects.map(\.colorHex)).count,
            "topicWords": Dictionary(uniqueKeysWithValues: profile.subjects.map { ($0.name, $0.keywords.count) }),
            "weekdayWindows": profile.studyPreferences.weekdayWindows.map { "\($0.start)–\($0.end)" },
            "weekendWindows": profile.studyPreferences.weekendWindows.count,
            "sessionMinutes": profile.studyPreferences.sessionMinutes,
            "schoolHours": profile.studyPreferences.schoolHours.map { "\($0.start)–\($0.end)" } ?? "none",
            "name": profile.studentName ?? "",
            "documentTypes": profile.documentTypes.map(\.name),
        ]
    }

    /// Enters a Week A/B timetable with a class on right now, then checks the
    /// planner shows it and a file arriving now points to its subject. The
    /// timetable stays, so the restart run can check it was saved.
    private static func checkTimetable(_ model: AppModel) async -> [String: Any] {
        let calendar = model.calendar
        let now = Date.now
        let subject = model.subjects.first { $0.name == "Physics" } ?? model.subjects[0]
        var timetable = model.newTimetable()
        timetable.weekCount = 2
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let period = SchoolTimetable.Period(name: "Self-test period", start: max(minute - 30, 0), end: min(minute + 30, 24 * 60 - 1))
        timetable.periods = [period]
        timetable.setSubject(subject.id, week: timetable.week(of: now, calendar: calendar), weekday: calendar.component(.weekday, from: now), period: period.id)
        model.profile.timetable = timetable
        // Settings save after a short pause, and the run ends sooner than that.
        try? model.live?.profileStore.save(model.profile)

        let classes = model.timetableClasses(on: now)
        let arriving = Evidence(fileName: "worksheet.pdf", contentType: "com.adobe.pdf", text: "Questions 1 to 10", arrived: now)
        let vote = await TimetableVoter(classes: classes).vote(on: arriving, profile: model.profile)
        return [
            "week": model.weekName(for: now) ?? "none",
            "classesToday": classes.map(\.title),
            "schoolHoursToday": model.schoolHours(on: now).map { "\($0.start)–\($0.end)" } ?? "none",
            "vote": vote.top.flatMap { model.subject($0.id)?.name } ?? "none",
            "reasons": vote.reasons,
        ]
    }

    /// Backs up the live records to a file, then restores it into a separate
    /// empty store as if the School folder had moved. The app's own records
    /// aren't touched.
    private static func checkBackup(_ model: AppModel, in folder: URL) -> [String: Any] {
        guard let live = model.live, let library = model.libraryURL else { return ["error": "Not set up"] }
        do {
            let backup = FolioBackup(profile: model.profile, store: live.store, library: library, preferences: .init(watchesDownloads: true))
            let file = folder.appending(path: "Self-test.\(FolioBackup.fileExtension)")
            try backup.encoded().write(to: file, options: .atomic)
            let read = try FolioBackup.decode(Data(contentsOf: file))
            let moved = folder.appending(path: "Moved School", directoryHint: .isDirectory)
            let fresh = try FolioStore(url: nil)
            let restored = try read.restore(into: fresh, library: moved, fileExists: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
            return [
                "bytes": (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                "filed": "\(restored.filed) of \(live.store.filedItems().count)",
                "waiting": "\(restored.waiting) of \(live.store.reviewEntries().count)",
                "examples": "\(restored.examples) of \(live.store.examples().count)",
                "assessments": "\(restored.assessments) of \(live.store.assessmentRecords().count)",
                "linkedFiles": "\(fresh.filedItems().filter { $0.assessmentID != nil }.count) of \(live.store.filedItems().filter { $0.assessmentID != nil }.count)",
                "sessions": "\(restored.sessions) of \(live.store.plannedSessions().count)",
                "flashcards": "\(restored.flashcards) of \(live.store.flashcardRecords().count)",
                "practice": "\(restored.practice) of \(live.store.practiceRecords().count)",
                "todos": "\(restored.todos) of \(live.store.todoRecords().count)",
                "plannedSteps": "\(fresh.plannedSessions().flatMap(\.session.plan).count) of \(live.store.plannedSessions().flatMap(\.session.plan).count)",
                "samePlaces": Set(fresh.filedItems().map(\.relativePath)) == Set(live.store.filedItems().map(\.relativePath)),
                "timetable": read.profile.timetable?.summary ?? "none",
            ]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Saves, reads and deletes a made-up password, to show the sandboxed app
    /// can keep a Claude key in the keychain. The real key is never touched,
    /// and macOS doesn't ask because this build made the item it reads.
    private static func checkKeychain() -> String {
        let item = Keychain(service: "\(Bundle.main.bundleIdentifier ?? "Folio").self-test-\(UUID().uuidString)", account: "self-test", label: "Folio self-test (safe to delete)")
        defer { try? item.delete() }
        do {
            try item.save("sk-ant-self-test")
            guard item.hasPassword, try item.password() == "sk-ant-self-test" else { return "saved, but couldn't read it back" }
            try item.delete()
            return item.hasPassword ? "couldn't delete it" : "works"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    /// Drops a task notification on Folio, as a student would, and checks it's
    /// offered as an assessment with its details, then added with the file linked.
    private static func checkAssessmentFromFile(_ model: AppModel, in folder: URL) async -> [String: Any] {
        let due = model.calendar.date(byAdding: .day, value: 24, to: model.calendar.startOfDay(for: .now))!
        let dueText = due.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "en_AU")))
        let sheets = folder.appending(path: "Task sheets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        let file = sheets.appending(path: "English Task 3 notification.txt")
        let text = """
            Assessment Notification
            English Advanced – Year 12
            Task 3: Persuasive speech on a prescribed text
            Weighting: 20%
            Due date: \(dueText), 3:00 pm
            Outcomes assessed: EA12-1, EA12-5
            Total marks: 30
            Write and deliver a persuasive speech analysing how the poet uses language, imagery,
            rhetoric and form to shape meaning for an audience. Refer closely to the poems and
            to the context of the novel and essay studied this term.
            """
        try? text.write(to: file, atomically: true, encoding: .utf8)

        let before = Set(model.assessmentSuggestions.map(\.id))
        model.addFiles([file])
        await waitUntil(seconds: 120) { model.sorting.allSatisfy(\.isDone) }
        if let waiting = model.needsReview.first(where: { $0.name == file.lastPathComponent }) {
            let english = model.subjects.first { $0.name == "English" } ?? model.subjects[0]
            model.file(waiting, in: english.id)
            await waitUntil(seconds: 30) { !model.needsReview.contains { $0.id == waiting.id } }
        }
        await waitUntil(seconds: 10) { model.assessmentSuggestions.contains { !before.contains($0.id) } }
        guard let suggestion = model.assessmentSuggestions.first(where: { !before.contains($0.id) }),
              case .new(let found) = suggestion.offer
        else {
            return ["error": "No assessment was offered", "sorting": model.sorting.map(\.detail)]
        }
        model.accept(suggestion)
        let added = model.assessments.first { $0.title == found.title }
        return [
            "title": found.title,
            "kind": found.kind.rawValue,
            "weighting": found.weighting ?? -1,
            "totalMarks": found.totalMarks ?? -1,
            "dueRight": model.calendar.isDate(found.due, inSameDayAs: due) && model.calendar.component(.hour, from: found.due) == 15,
            "subject": model.subject(suggestion.subjectID)?.name ?? "?",
            "added": added != nil,
            "milestones": added?.milestones.map(\.title) ?? [],
            "linkedFiles": added.map { model.linkedFiles(of: $0).map { "\($0.name) (\($0.role?.rawValue ?? "?"))" } } ?? [],
        ]
    }

    /// Tries each study tool on the files the run filed: reads the library
    /// for searching and searches it, writes flashcards from a note with the
    /// on-device AI and keeps them, summarises it, runs the timer and records
    /// how it went, and practises a past paper. Nothing is opened on screen.
    private static func checkStudy(_ model: AppModel) async -> [String: Any] {
        var report: [String: Any] = [:]
        let clock = ContinuousClock()

        var start = clock.now
        await model.updateSearchIndex(pause: .zero)
        report["indexSeconds"] = (clock.now - start).components.seconds
        report["indexedFiles"] = model.live?.store.indexedFiles().count ?? 0
        report["search"] = await model.searchFiles("electromagnetic induction").prefix(3).map { "\($0.file.name) (\($0.matched.joined(separator: ", ")))" }
        report["searchNothing"] = await model.searchFiles("photosynthesis chloroplasts").count
        if let notes = model.libraryFiles.first(where: { $0.name == "Electromagnetism notes.docx" }), let url = notes.url {
            report["related"] = model.relatedFiles(to: url).prefix(3).map(\.name)

            start = clock.now
            let writing = await model.writeCards(from: url, subjectID: notes.subjectID, withClaude: false) { _ in }
            report["cardSeconds"] = (clock.now - start).components.seconds
            report["cardsWritten"] = writing.drafts.map { "\($0.question) → \($0.answer)" }
            report["cardProblem"] = writing.message ?? "none"
            model.keep(writing.drafts, from: writing, subjectID: notes.subjectID)
            if let first = model.flashcards.first {
                let answered = model.answer(first, knewIt: true)
                report["afterKnowingOne"] = "box \(answered.box), due \(answered.due.formatted(.dateTime.weekday().day().month()))"
            }
            report["dueCards"] = model.dueCards().count

            start = clock.now
            switch await model.summary(of: url, progress: { _ in }) {
            case .success(let points): report["summary"] = points
            case .failure(let problem): report["summary"] = "failed: \(problem.message)"
            }
            report["summarySeconds"] = (clock.now - start).components.seconds
        } else {
            report["cards"] = "Electromagnetism notes.docx wasn't filed"
        }

        // A task sheet is never used for cards.
        if let sheet = model.libraryFiles.first(where: { $0.name.hasPrefix("English Task 3") }), let url = sheet.url {
            report["taskSheetRefused"] = model.cardRefusal(for: url, text: model.indexedText(at: url)) != nil
        }

        // The timer, with no files, so nothing opens: started, given a plan of
        // two steps with one ticked off, ended early, and recorded as partly
        // done. The step left should move on to the next Physics session.
        if let subject = model.subjects.first(where: { $0.name == "Physics" }) {
            model.startFocus(subjectID: subject.id, minutes: 25, title: "Self-test study", files: [])
            let sessionID = model.focus?.sessionID
            if let sessionID {
                model.addStep(titled: "Self-test step done", to: sessionID)
                model.addStep(titled: "Self-test step left", to: sessionID)
                if let first = model.session(sessionID)?.plan.first {
                    model.setStep(first, in: sessionID, done: true)
                }
            }
            model.pauseFocus()
            model.resumeFocus()
            model.endFocus()
            let wasOver = model.focus?.isOver == true
            model.finishFocus(outcome: .partly, minutes: 20, note: "Self-test note")
            let recorded = model.sessions.last { $0.title == "Self-test study" }
            let carriedTo = model.sessions.first { $0.id != sessionID && $0.plan.contains { $0.title == "Self-test step left" } }
            report["timer"] = [
                "inPlannerWhileRunning": sessionID != nil,
                "endedAskingHowItWent": wasOver,
                "recorded": recorded.map { "\($0.outcome?.rawValue ?? "?"), \($0.doneMinutes ?? 0) min, \($0.note ?? "")" } ?? "nothing",
                "plan": recorded?.plan.map { "\($0.title)\($0.isDone ? " ✓" : "")" } ?? [],
                "stepLeftWentTo": carriedTo.map { "\(model.subject($0.subjectID)?.name ?? "?") \($0.start.formatted(.dateTime.weekday().hour().minute()))" }
                    ?? (model.todos.contains { $0.title == "Self-test step left" } ? "the to-do list" : "nowhere"),
                "studiedThisWeek": model.studyMinutes(inWeekOf: .now).recorded,
            ]

            let papers = model.papers(of: subject.id)
            report["physicsPapers"] = papers.map { "\($0.title) (\($0.file.name), \($0.guidelines.count) guidelines)" }
            if let paper = papers.first {
                model.savePractice(PracticeAttempt(subjectID: subject.id, paperName: paper.file.name, minutes: 170, mark: Assessment.Mark(score: 74, outOf: 100), note: "Self-test"))
                report["paperMinutes"] = model.workingMinutes(of: paper) ?? -1
            }
        }
        report["practiceAttempts"] = model.practiceAttempts.count
        return report
    }

    /// Plans inside sessions, a session the student made, and to-dos: adds a
    /// to-do and a Chemistry session of the student's own next week, then
    /// plans the week again. The own session should stay where it is with
    /// nothing on top of it, the to-do should go into one English session,
    /// and planning a second time shouldn't add it twice.
    private static func checkPlans(_ model: AppModel) -> [String: Any] {
        let calendar = model.calendar
        let week = calendar.date(byAdding: .weekOfYear, value: 1, to: model.weekStart(containing: .now))!
        let english = model.subjects.first { $0.name == "English" } ?? model.subjects[0]
        let chemistry = model.subjects.first { $0.name == "Chemistry" } ?? model.subjects[1]
        guard let todo = model.addTodo("Self-test to-do", subjectID: english.id, minutes: 20) else { return ["error": "Couldn't add a to-do"] }

        let start = calendar.date(byAdding: DateComponents(day: 4, hour: 16, minute: 30), to: week)!
        let own = StudySession(subjectID: chemistry.id, start: start, end: start.addingTimeInterval(90 * 60), plan: [PlanStep(title: "Self-test own step")])
        model.saveSession(own)
        let firstAdded = model.planWeek(containing: week)
        let secondAdded = model.planWeek(containing: week)

        let kept = model.session(own.id)
        let planned = model.sessions.filter { $0.start >= week && $0.start < calendar.date(byAdding: .day, value: 7, to: week)! }
        let onTop = planned.filter { $0.id != own.id && $0.start < own.end && own.start < $0.end }
        let withTodo = planned.filter { $0.plan.contains { $0.kind == .todo && $0.reference == todo.id.uuidString } }
        let suggestions = kept.map { model.suggestions(for: $0).map(\.title) } ?? []

        // Ticking the to-do in its session ticks it off the list.
        if let session = withTodo.first, let step = session.plan.first(where: { $0.reference == todo.id.uuidString }) {
            model.setStep(step, in: session.id, done: true)
        }
        return [
            "addedFirstTime": firstAdded,
            "addedSecondTime": secondAdded,
            "ownSessionKept": kept?.start == own.start && kept?.isOwn == true,
            "ownSessionPlan": kept?.plan.map(\.title) ?? [],
            "sessionsOnTopOfIt": onTop.count,
            "sessionsWithTheTodo": withTodo.map { "\(model.subject($0.subjectID)?.name ?? "?") \($0.title ?? "general")" },
            "todoTickedOffWithItsStep": model.todos.first { $0.id == todo.id }?.isDone == true,
            "suggestionsForOwnSession": suggestions,
        ]
    }

    /// Progress: marks the essay and checks the mark is dated and averaged,
    /// reviews this week, then adds three things due in one week a month out
    /// and starts the work earlier, which the restart run should still find.
    /// The Sunday reminder isn't turned on, so nothing asks for notifications.
    private static func checkProgress(_ model: AppModel) -> [String: Any] {
        let calendar = model.calendar
        var report: [String: Any] = [:]
        if var essay = model.assessments.first(where: { $0.title == "Self-test essay" }) {
            essay.status = .marked
            essay.mark = Assessment.Mark(score: 18, outOf: 20)
            model.saveAssessment(essay)
            let saved = model.assessment(essay.id)
            report["markDated"] = saved?.markedAt.map { abs($0.timeIntervalSinceNow) < 120 } ?? false
            report["englishAverage"] = model.standing(of: essay.subjectID).average.map(ProgressFormat.percent) ?? "none"
        }
        let review = model.weekReview(startingOn: model.weekStart(containing: .now))
        report["thisWeek"] = [
            "studied": review.studied, "planned": review.planned, "done": review.done, "partly": review.partly,
            "marksBack": review.marksBack.map(\.title), "dueNextWeek": review.dueNext.map(\.title),
        ]

        let busy = calendar.date(byAdding: .weekOfYear, value: 4, to: model.weekStart(containing: .now))!
        let names = ["Self-test depth study", "Self-test mechanics test", "Self-test history essay"]
        for (index, name) in names.enumerated() {
            let due = calendar.date(byAdding: DateComponents(day: index * 2, hour: 9), to: busy)!
            model.saveAssessment(Assessment(title: name, subjectID: model.subjects[index % model.subjects.count].id, kind: index == 1 ? .test : .task, due: due, weighting: 20))
        }
        let warnings = model.workloadWarnings()
        report["busyWeeks"] = warnings.map { "\(WorkloadText.title($0, calendar: calendar)): \($0.due.map(\.title).joined(separator: ", "))" }
        if let warning = warnings.first(where: { warning in warning.due.contains { names.contains($0.title) } }) {
            report["suggestedEarlierStarts"] = warning.startEarlier.map { "\($0.title) from \($0.from.formatted(.dateTime.day().month()))" }
            model.startEarlier(warning.startEarlier)
        }
        report["startingEarlier"] = model.assessments.filter { $0.planFrom != nil }.map(\.title)
        let summary = model.termSummary(TermRequest(title: "Self-test", subjectIDs: model.subjects.map(\.id)))
        report["termSoFar"] = ["studied": summary.studied, "files": summary.files, "average": summary.standing.average.map(ProgressFormat.percent) ?? "none"]
        report["reviewWaitingOnToday"] = model.isWeeklyReviewWaiting()
        report["remindsWeeklyReview"] = model.remindsWeeklyReview
        return report
    }

    /// What the Today screen shows, from the same data.
    private static func checkToday(_ model: AppModel) -> [String: Any] {
        let next = model.nextSession()
        return [
            "nextSession": next.map { "\(model.subject($0.subjectID)?.name ?? "?") · \($0.title ?? "general") at \($0.start.formatted(.dateTime.weekday().hour().minute()))" } ?? "none",
            "dueSoon": model.upcomingAssessments(within: 14).map(\.title),
            "classesToday": model.classes(on: .now).count,
        ]
    }

    /// Adds a task and an exam and plans next week around made-up events.
    /// Nothing should overlap a timed event, the time kept free around it, or
    /// the exam; work for both should come before they're due; and the
    /// restart run should find the same assessments and sessions.
    private static func checkPlanner(_ model: AppModel) -> [String: Any] {
        let calendar = model.calendar
        let week = calendar.date(byAdding: .weekOfYear, value: 1, to: model.weekStart(containing: .now))!
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: week)! }
        func event(_ title: String, _ offset: Int, _ start: Double, _ end: Double) -> BusyBlock {
            BusyBlock(id: title, title: title, start: day(offset).addingTimeInterval(start * 3600), end: day(offset).addingTimeInterval(end * 3600), calendarID: "self-test")
        }
        model.isCalendarConnected = true
        model.calendarEvents = [
            event("Netball training", 0, 16, 19.5),
            event("Tutoring", 1, 16.5, 17.5),
            event("Work", 5, 9, 12.5),
            BusyBlock(id: "excursion", title: "Excursion", start: day(2), end: day(3), isAllDay: true, calendarID: "self-test"),
        ]
        let english = model.subjects.first { $0.name == "English" } ?? model.subjects[0]
        let chemistry = model.subjects.first { $0.name == "Chemistry" } ?? model.subjects[1]
        let essay = Assessment(title: "Self-test essay", subjectID: english.id, due: day(3).addingTimeInterval(9 * 3600), weighting: 25)
        let exam = Assessment(title: "Self-test exam", subjectID: chemistry.id, kind: .exam, due: day(5).addingTimeInterval(13 * 3600), lengthMinutes: 120, weighting: 30)
        model.saveAssessment(essay)
        model.saveAssessment(exam)
        let added = model.planWeek(containing: week)

        let buffer = TimeInterval(model.profile.studyPreferences.bufferMinutes * 60)
        let timed = model.calendarEvents.filter { !$0.isAllDay }
        let planned = model.sessions.filter { $0.start >= week && $0.start < day(7) }
        let sitting = exam.sitting!
        let clashes = planned.filter { session in
            timed.contains { $0.start.addingTimeInterval(-buffer) < session.end && session.start < $0.end.addingTimeInterval(buffer) }
                || (sitting.start < session.end && session.start < sitting.end)
        }
        let essayWork = planned.filter { $0.assessmentID == essay.id }
        let revision = planned.filter { $0.assessmentID == exam.id }
        return [
            "sessionsAdded": added,
            "clashes": clashes.count,
            "onTheExcursionDay": planned.filter { calendar.isDate($0.start, inSameDayAs: day(2)) }.count,
            "essaySessions": essayWork.count,
            "essayWorkBeforeDueDay": essayWork.allSatisfy { $0.end <= calendar.startOfDay(for: essay.due) },
            "revisionSessions": revision.count,
            "revisionBeforeExamDay": revision.allSatisfy { $0.end <= calendar.startOfDay(for: exam.due) },
            "sessions": planned.map { "\(model.subject($0.subjectID)?.name ?? "?") \($0.title.map { "(\($0)) " } ?? "")\($0.start.formatted(.dateTime.weekday().hour().minute()))–\($0.end.formatted(.dateTime.hour().minute()))" },
            "assessments": model.assessments.map(\.title),
        ]
    }

    private static func state(of model: AppModel) -> [String: Any] {
        [
            "phase": name(of: model.phase),
            "aiNotice": model.aiNotice ?? "",
            "learnedExamples": model.learnedExampleCount,
            "sorting": model.sorting.map { ["name": $0.name, "status": describe($0.status, model), "detail": $0.detail] },
            "recentlySorted": model.recentlySorted.map { ["name": $0.name, "location": model.location(of: $0.subjectID, folder: $0.folder)] },
            "needsReview": model.needsReview.map {
                [
                    "name": $0.name,
                    "question": $0.question,
                    "suggestions": $0.suggestions.compactMap { model.subject($0)?.name },
                    "reasons": $0.reasons,
                ] as [String: Any]
            },
            "folders": Dictionary(uniqueKeysWithValues: model.subjects.map { subject in
                (subject.name, model.folders(of: subject.id).map { "\($0.name): \($0.fileCount)" })
            }),
        ]
    }

    private static func describe(_ status: SortingItem.Status, _ model: AppModel) -> String {
        switch status {
        case .reading: "reading"
        case .filed(let subject, let folder): "filed in \(model.location(of: subject, folder: folder))"
        case .needsLook: "needs a look"
        case .leftAlone: "left alone"
        case .duplicate: "duplicate"
        case .failed: "failed"
        }
    }

    private static func name(of phase: AppModel.Phase) -> String {
        phase == .setup ? "setup" : "ready"
    }

    private static func relativePaths(in folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            paths.append(String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count)))
        }
        return paths.sorted()
    }

    private static func waitUntil(seconds: Int, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func finish(_ report: [String: Any], at url: URL) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        exit(0)
    }
}
#endif
