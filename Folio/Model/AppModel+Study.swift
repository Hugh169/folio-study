import AppKit
import FolioKit
import SwiftUI

/// A study session running with the timer.
struct FocusSession: Equatable {
    /// The session in the planner it's for. Study that wasn't planned gets
    /// one when the timer starts, so it has a plan like any other.
    var sessionID: StudySession.ID?
    /// The session was made for this timer, rather than planned beforehand.
    var isUnplanned = false
    var subjectID: Subject.ID
    var assessmentID: Assessment.ID?
    /// What it's for, such as "Depth Study: Draft".
    var title: String?
    /// How long the student means to study, including time they added.
    var minutes: Int
    var startedAt: Date
    /// Time studied before the timer was last paused.
    var banked: TimeInterval = 0
    /// When the timer last started running, or `nil` while it's paused.
    var runningSince: Date?
    /// The files for it, to have open.
    var files: [URL] = []
    /// The past paper being practised, if it's practice.
    var paper: PastPapers.Paper?
    /// Time's up, or the student ended it: time to say how it went.
    var isOver = false

    var isPaused: Bool { runningSince == nil }

    func studied(at now: Date) -> TimeInterval {
        banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, TimeInterval(minutes * 60) - studied(at: now))
    }

    /// When time runs out, while the timer's running.
    var endsAt: Date? {
        runningSince.map { $0.addingTimeInterval(TimeInterval(minutes * 60) - banked) }
    }

    /// From 0 at the start to 1 when time's up.
    func progress(at now: Date) -> Double {
        minutes > 0 ? min(1, studied(at: now) / TimeInterval(minutes * 60)) : 1
    }
}

/// Cards written from one file, waiting for the student to choose which to keep.
struct CardWriting {
    var drafts: [CardDraft] = []
    var origin: Flashcard.Origin = .onDevice
    var sourceID: UUID?
    var sourceName: String
    /// Why there are no cards, or something to know about the ones there are.
    var message: String?
    /// Cards dropped because their answers weren't in the file.
    var dropped = 0
    /// The file looked like questions, such as an exam paper, so Folio stopped before writing.
    var isMostlyQuestions = false
}

/// A file found by searching, with the words that matched.
struct SearchHit: Identifiable {
    var file: SortedFile
    var matched: [String]
    var id: SortedFile.ID { file.id }
}

extension AppModel {
    private static let timerSoundKey = "playsTimerSound"

    /// Whether to play a sound when the study timer runs out.
    var playsTimerSound: Bool {
        get { settings.object(forKey: Self.timerSoundKey) as? Bool ?? true }
        set { settings.set(newValue, forKey: Self.timerSoundKey) }
    }

    // MARK: Loading

    func loadStudy() {
        guard let live else { return }
        flashcards = live.store.flashcardRecords().map(\.card)
        practiceAttempts = live.store.practiceRecords().map(\.attempt)
        loadTodos()
    }

    // MARK: The study timer

    /// The files for a session: its assessment's linked files, or else the subject's latest.
    func materials(for session: StudySession) -> [URL] {
        materials(subjectID: session.subjectID, assessmentID: session.assessmentID)
    }

    func materials(subjectID: Subject.ID, assessmentID: Assessment.ID?) -> [URL] {
        if let id = assessmentID, let assessment = assessment(id) {
            let linked = linkedFiles(of: assessment).compactMap(\.url)
            if !linked.isEmpty { return Array(linked.prefix(4)) }
        }
        return Array(recentlySorted.filter { $0.subjectID == subjectID }.compactMap(\.url).prefix(3))
    }

    /// Starts the timer for a planned session and opens its files. The
    /// session becomes the student's own, so replanning the week while it
    /// runs doesn't move it.
    func startFocus(_ session: StudySession, now: Date = .now) {
        let files = materials(for: session)
        if let index = sessions.firstIndex(where: { $0.id == session.id }), !sessions[index].isOwn {
            sessions[index].isOwn = true
            saveSessions()
        }
        begin(FocusSession(
            sessionID: session.id, subjectID: session.subjectID, assessmentID: session.assessmentID, title: session.title,
            minutes: max(5, session.minutes), startedAt: now, runningSince: now, files: files
        ))
        files.forEach(open)
    }

    /// Starts the timer for study that wasn't planned, opening `files`. It
    /// goes in the planner straight away as the student's own session.
    func startFocus(subjectID: Subject.ID, minutes: Int, title: String? = nil, assessmentID: Assessment.ID? = nil, files: [URL]? = nil, paper: PastPapers.Paper? = nil, now: Date = .now) {
        let files = files ?? materials(subjectID: subjectID, assessmentID: assessmentID)
        let minutes = max(5, minutes)
        let session = StudySession(
            subjectID: subjectID, start: now, end: now.addingTimeInterval(TimeInterval(minutes * 60)),
            assessmentID: assessmentID, title: title, isOwn: true
        )
        sessions.append(session)
        saveSessions()
        begin(FocusSession(
            sessionID: session.id, isUnplanned: true, subjectID: subjectID, assessmentID: assessmentID, title: title, minutes: minutes,
            startedAt: now, runningSince: now, files: files, paper: paper
        ))
        files.forEach(open)
    }

    private func begin(_ session: FocusSession) {
        focus = session
        scheduleTimeUp()
    }

    func pauseFocus(now: Date = .now) {
        guard var focus, !focus.isPaused else { return }
        focus.banked = focus.studied(at: now)
        focus.runningSince = nil
        self.focus = focus
        focusTimer?.cancel()
    }

    func resumeFocus(now: Date = .now) {
        guard var focus, focus.isPaused, !focus.isOver else { return }
        focus.runningSince = now
        self.focus = focus
        scheduleTimeUp()
    }

    /// Adds time, and starts the timer again if time was up.
    func extendFocus(by minutes: Int, now: Date = .now) {
        guard var focus else { return }
        focus.minutes += minutes
        if focus.isOver {
            focus.isOver = false
            focus.runningSince = now
        }
        self.focus = focus
        scheduleTimeUp()
    }

    /// Stops the timer and asks how it went.
    func endFocus(now: Date = .now) {
        pauseFocus(now: now)
        focus?.isOver = true
    }

    private func stopTimer() {
        focusTimer?.cancel()
        focus = nil
    }

    private func scheduleTimeUp() {
        focusTimer?.cancel()
        guard let end = focus?.endsAt else { return }
        focusTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.timeIsUp()
        }
    }

    /// The timer ran out: say so with a sound and, when Folio is in the background, a notification.
    func timeIsUp(now: Date = .now) {
        guard var focus, !focus.isOver else { return }
        focus.banked = focus.studied(at: now)
        focus.runningSince = nil
        focus.isOver = true
        self.focus = focus
        if playsTimerSound {
            NSSound(named: "Glass")?.play()
        }
        if notificationsAllowed == true, !NSApp.isActive {
            let name = subject(focus.subjectID)?.name ?? ""
            live?.notifier.timeIsUp(name, title: focus.title)
        }
    }

    /// Records how the session went, stops the timer, and saves a past
    /// paper's mark. Study that wasn't planned stays in the planner where it
    /// happened, so it counts towards the assessment it was for. Done ticks
    /// off the whole plan; otherwise what's left of it moves on to the next
    /// session for the same work.
    func finishFocus(outcome: StudySession.Outcome, minutes: Int, note: String, mark: Assessment.Mark? = nil, now: Date = .now) {
        guard let focus else { return }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = outcome == .skipped ? 0 : max(0, minutes)
        if let id = focus.sessionID, let index = sessions.firstIndex(where: { $0.id == id }) {
            if focus.isUnplanned && outcome == .skipped {
                // Unplanned study that didn't happen isn't kept, but its plan is.
                let dropped = sessions.remove(at: index)
                carrySteps(of: dropped, now: now)
            } else {
                sessions[index].doneMinutes = minutes
                sessions[index].outcome = outcome
                sessions[index].note = note.isEmpty ? nil : note
                if focus.isUnplanned {
                    sessions[index].end = max(now, sessions[index].start.addingTimeInterval(60))
                }
                finishPlan(at: index, outcome: outcome, now: now)
            }
        } else if outcome != .skipped {
            let end = max(now, focus.startedAt.addingTimeInterval(60))
            sessions.append(StudySession(
                subjectID: focus.subjectID, start: focus.startedAt, end: end, assessmentID: focus.assessmentID,
                title: focus.title, doneMinutes: minutes, outcome: outcome, note: note.isEmpty ? nil : note, isOwn: true
            ))
        }
        saveSessions()
        if let paper = focus.paper {
            savePractice(PracticeAttempt(
                subjectID: focus.subjectID, paperName: paper.file.name,
                paperID: paper.file.url.flatMap { live?.librarian?.filedItemID(at: $0) },
                date: focus.startedAt, minutes: minutes, mark: mark, note: note
            ))
        }
        if outcome != .skipped, let id = focus.assessmentID, let assessment = assessment(id), assessment.status == .notStarted {
            setStatus(.inProgress, of: assessment)
        }
        stopTimer()
    }

    /// Records a planned session as done or skipped without the timer.
    func record(_ session: StudySession, as outcome: StudySession.Outcome, now: Date = .now) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].outcome = outcome
        sessions[index].doneMinutes = outcome == .skipped ? 0 : session.minutes
        finishPlan(at: index, outcome: outcome, now: now)
        saveSessions()
    }

    /// Minutes recorded with the timer or marked done in the week containing
    /// `date`, and minutes planned that week. Sessions that weren't recorded
    /// aren't counted as studied here, so the number is honest.
    func studyMinutes(inWeekOf date: Date) -> (recorded: Int, planned: Int) {
        let start = weekStart(containing: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let week = sessions.filter { $0.start >= start && $0.start < end }
        let recorded = week.compactMap { $0.outcome == .skipped ? 0 : $0.doneMinutes }.reduce(0, +)
        let planned = week.filter { $0.outcome == nil || $0.outcome != .skipped }.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
        return (recorded, planned)
    }

    /// Sessions the student recorded, newest first.
    func recordedSessions(limit: Int = 6) -> [StudySession] {
        Array(sessions.filter(\.isRecorded).sorted { $0.start > $1.start }.prefix(limit))
    }

    // MARK: Flashcards

    func cards(of subjectID: Subject.ID) -> [Flashcard] {
        flashcards.filter { $0.subjectID == subjectID }
    }

    func dueCards(at now: Date = .now, in subjectID: Subject.ID? = nil) -> [Flashcard] {
        Flashcard.dueCards(subjectID.map(cards(of:)) ?? flashcards, at: now)
    }

    /// Adds new cards and saves changes to others.
    func saveCards(_ cards: [Flashcard]) {
        for card in cards {
            if let index = flashcards.firstIndex(where: { $0.id == card.id }) {
                flashcards[index] = card
            } else {
                flashcards.append(card)
            }
        }
        live?.store.save(cards)
    }

    func deleteCards(_ ids: Set<UUID>) {
        flashcards.removeAll { ids.contains($0.id) }
        live?.store.deleteFlashcards(ids)
    }

    /// Moves a card up a box or back to the first, and saves it.
    @discardableResult
    func answer(_ card: Flashcard, knewIt: Bool, now: Date = .now) -> Flashcard {
        let answered = card.answered(knewIt: knewIt, at: now, calendar: calendar)
        saveCards([answered])
        return answered
    }

    /// Why Folio won't make cards from a file: a task sheet or marking
    /// criteria, or a file in a subject's assessments folder, so it never
    /// writes answers for an assessment.
    func cardRefusal(for url: URL, text: String? = nil) -> String? {
        let refusal = String(localized: "Folio doesn't make cards from task sheets or marking criteria, so it never writes answers for an assessment.")
        if isAssessmentFile(url, folder: libraryFile(at: url)?.folder, linked: assessmentSheetPaths()) {
            return refusal
        }
        if let text, let reading = AssessmentReader.read(Evidence(fileName: url.lastPathComponent, contentType: "public.text", text: text)),
           reading.assessment != nil || reading.role == .taskSheet || reading.role == .criteria {
            return refusal
        }
        return nil
    }

    /// The task sheets and marking criteria linked to assessments.
    func assessmentSheetPaths() -> Set<String> {
        let sheets: [LinkedFile] = assessments.flatMap { linkedFiles(of: $0) }.filter { $0.role == .taskSheet || $0.role == .criteria }
        return Set(sheets.compactMap { $0.url.map(Self.path(of:)) })
    }

    /// Whether Folio knows a file is for an assessment without reading it:
    /// a linked task sheet or criteria, or a file in an assessments folder.
    func isAssessmentFile(_ url: URL, folder: String?, linked: Set<String>) -> Bool {
        if linked.contains(Self.path(of: url)) { return true }
        guard let folder = folder?.lowercased() else { return false }
        return ["assessment", "sac", "coursework", "assignment"].contains(where: folder.contains)
    }

    /// Reads a file thoroughly and writes cards from it, on this Mac or with
    /// Claude. `progress` hears what's happening, such as "Writing cards… 3 of 8".
    func writeCards(from url: URL, subjectID: Subject.ID, withClaude: Bool, anyway: Bool = false, progress: @escaping @MainActor @Sendable (String) -> Void) async -> CardWriting {
        var writing = CardWriting(origin: withClaude ? .claude : .onDevice, sourceID: live?.librarian?.filedItemID(at: url), sourceName: url.lastPathComponent)
        if let refusal = cardRefusal(for: url) {
            writing.message = refusal
            return writing
        }
        guard let librarian = live?.librarian else {
            writing.message = String(localized: "Folio needs your School folder to read files.")
            return writing
        }
        progress(String(localized: "Reading “\(url.lastPathComponent)”…"))
        let evidence: Evidence
        do {
            evidence = try await librarian.readThoroughly(url) { message in
                Task { @MainActor in progress(message) }
            }
        } catch {
            writing.message = String(localized: "Folio couldn't read this file.")
            return writing
        }
        if let refusal = cardRefusal(for: url, text: evidence.text) {
            writing.message = refusal
            return writing
        }
        if !anyway && CardWriter.looksLikeQuestions(evidence.text) {
            writing.message = String(localized: "This looks like questions, such as an exam paper or a worksheet, so the answers probably aren't in it. Cards work best from notes.")
            writing.isMostlyQuestions = true
            return writing
        }
        let subjectName = subject(subjectID)?.name ?? ""
        if withClaude, let key = live?.claudeKey {
            progress(String(localized: "Claude is writing cards…"))
            let result = await ClaudeCardWriter(key: key, ledger: live?.claudeLedger).cards(from: evidence.text, subject: subjectName)
            refreshClaudeUsage()
            writing.drafts = result.drafts
            writing.dropped = result.notInNotes
            writing.message = result.problem?.message
        } else {
            let result = await CardWriter().cards(from: evidence.text, subject: subjectName) { done, total in
                Task { @MainActor in
                    progress(String(localized: "Writing cards… part \(min(done + 1, total)) of \(total)"))
                }
            }
            writing.drafts = result.drafts
            writing.dropped = result.notInNotes
            writing.message = result.problem?.message
        }
        if writing.drafts.isEmpty && writing.message == nil {
            writing.message = String(localized: "No cards came out of this file. Cards work best from notes that explain things.")
        }
        return writing
    }

    /// Keeps the drafts the student chose as cards. They're due from the start
    /// of today, so screens that last checked the time a moment ago count them.
    func keep(_ drafts: [CardDraft], from writing: CardWriting, subjectID: Subject.ID, assessmentID: Assessment.ID? = nil, now: Date = .now) {
        saveCards(drafts.map { draft in
            Flashcard(
                subjectID: subjectID, question: draft.question, answer: draft.answer, sourceID: writing.sourceID,
                sourceName: writing.sourceName, quote: draft.quote, assessmentID: assessmentID, origin: writing.origin,
                due: calendar.startOfDay(for: now), createdAt: now
            )
        })
    }

    // MARK: Past papers

    /// A subject's past papers, paired with their marking guidelines, newest first.
    func papers(of subjectID: Subject.ID) -> [PastPapers.Paper] {
        let paperFolders = Set(profile.documentTypes.filter(PastPapers.holdsPapers).map { FolderTemplate.cleanFolderName($0.name).lowercased() })
        let facets = live?.librarian?.facetsByPath() ?? [:]
        // Task sheets and criteria linked to an assessment aren't papers, even if they were filed with them.
        let linked: [LinkedFile] = assessments(of: subjectID).flatMap { linkedFiles(of: $0) }
        let assessmentFiles: Set<String> = Set(linked.filter { $0.role == .taskSheet || $0.role == .criteria }.compactMap { $0.url.map(Self.path(of:)) })
        let files = libraryFiles.filter { file in
            guard file.subjectID == subjectID, let folder = file.folder, paperFolders.contains(folder.lowercased()) else { return false }
            return !assessmentFiles.contains(file.url.map(Self.path(of:)) ?? "")
        }
        let librarian = live?.librarian
        return PastPapers.papers(from: files.map { file in
            let found = file.url.flatMap { url in librarian.flatMap { facets[$0.pathInLibrary(url)] } }
            return PastPapers.File(name: file.name, url: file.url, year: found?.year, exam: found?.exam)
        })
    }

    /// The times the student practised a paper, newest first.
    func attempts(at paper: PastPapers.Paper) -> [PracticeAttempt] {
        practiceAttempts.filter { $0.paperName == paper.file.name }.sorted { $0.date > $1.date }
    }

    func savePractice(_ attempt: PracticeAttempt) {
        if let index = practiceAttempts.firstIndex(where: { $0.id == attempt.id }) {
            practiceAttempts[index] = attempt
        } else {
            practiceAttempts.append(attempt)
        }
        live?.store.save(attempt)
    }

    /// The paper's working time, read from its first page when Folio has read it for searching.
    func workingMinutes(of paper: PastPapers.Paper) -> Int? {
        guard let url = paper.file.url, let text = indexedText(at: url) else { return nil }
        return PastPapers.times(in: text).working
    }

    /// Starts the timer for a paper and opens it. The guidelines wait until the end.
    func practise(_ paper: PastPapers.Paper, minutes: Int, subjectID: Subject.ID) {
        startFocus(subjectID: subjectID, minutes: minutes, title: paper.title, files: paper.file.url.map { [$0] } ?? [], paper: paper)
    }

    // MARK: Searching

    /// Reads files in the library that aren't in the search index yet, then
    /// rebuilds search. Waits while files are being sorted.
    func updateSearchIndex(pause: Duration = .milliseconds(150)) async {
        guard let librarian = live?.librarian else { return }
        // Sorting reads files too, so wait for it, but not forever: a file
        // stuck in sorting mustn't stop search from ever updating.
        let latest = ContinuousClock.now + .seconds(15 * 60)
        while sorting.contains(where: { !$0.isDone }) || !backgroundSorting.isEmpty, ContinuousClock.now < latest {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
        }
        indexingProgress = (0, 0)
        await librarian.updateIndex(pause: pause) { [weak self] done, total in
            self?.indexingProgress = total > 0 && done < total ? (done, total) : nil
        }
        indexingProgress = nil
        rebuildSearch()
    }

    /// Reads the library for searching soon, once things have settled.
    func scheduleSearchIndexUpdate(after delay: Duration = .seconds(20)) {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.updateSearchIndex()
        }
    }

    func rebuildSearch() {
        guard let librarian = live?.librarian else { return }
        let records = librarian.indexedRecords()
        indexedLocations = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.url) })
        indexedTexts = Dictionary(records.map { ($0.url.standardizedFileURL.path(percentEncoded: false), $0.text) }, uniquingKeysWith: { first, _ in first })
        librarySearch = LibrarySearch(records.map { record in
            LibrarySearch.Document(id: record.id, name: record.url.lastPathComponent, text: record.text, embedding: record.embedding)
        })
    }

    /// Files whose text matches `query`, best first.
    func searchFiles(_ query: String) async -> [SearchHit] {
        guard let librarySearch else { return [] }
        let embedding = await embedder.embed(query)
        return librarySearch.search(query, queryEmbedding: embedding, limit: 30).compactMap { result in
            indexedLocations[result.id].flatMap(libraryFile(at:)).map { SearchHit(file: $0, matched: result.matched) }
        }
    }

    /// Files like the one at `url`: on the same topic, sharing its rarer words.
    func relatedFiles(to url: URL, limit: Int = 6) -> [SortedFile] {
        guard let librarySearch, let id = indexedLocations.first(where: { samePath($0.value, url) })?.key else { return [] }
        return librarySearch.related(to: id, limit: limit).compactMap { indexedLocations[$0.id].flatMap(libraryFile(at:)) }
    }

    /// The library file at `url`, with its subject and folder.
    func libraryFile(at url: URL) -> SortedFile? {
        libraryFiles.first { $0.url.map { samePath($0, url) } == true }
            ?? recentlySorted.first { $0.url.map { samePath($0, url) } == true }
    }

    /// The text Folio keeps for searching a file.
    func indexedText(at url: URL) -> String? {
        indexedTexts[url.standardizedFileURL.path(percentEncoded: false)]
    }

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        Self.path(of: a) == Self.path(of: b)
    }

    private static func path(of url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    // MARK: What's this?

    /// A file's main points, from the on-device AI, remembered while Folio runs.
    func summary(of url: URL, progress: @escaping @MainActor @Sendable (String) -> Void) async -> Result<[String], StudyAIProblem> {
        if let known = summaries[url] { return .success(known) }
        guard let librarian = live?.librarian else { return .failure(.unavailable(String(localized: "Folio needs your School folder to read files."))) }
        progress(String(localized: "Reading “\(url.lastPathComponent)”…"))
        guard let evidence = try? await librarian.readThoroughly(url, progress: { message in Task { @MainActor in progress(message) } }) else {
            return .failure(.failed(String(localized: "Folio couldn't read this file.")))
        }
        progress(String(localized: "Summarising…"))
        let result = await Summariser().summary(of: evidence.text, title: evidence.title)
        if case .success(let points) = result {
            summaries[url] = points
        }
        return result
    }
}
