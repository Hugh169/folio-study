import Foundation

/// Sorts files into the student's library and keeps the records: what was
/// filed where, what's waiting for a decision, and what Folio has learned.
///
/// It runs on the main actor because it owns the store; reading files and
/// asking the AI happen in the background in `SortingPipeline`, and moves run
/// on a background queue.
@MainActor
public final class Librarian {
    /// What happened to a file handed to `sort(_:)`, identified by its ticket.
    public enum Event: Sendable {
        case progress(UUID, String)
        case filed(UUID, FiledRecord)
        case needsReview(UUID, ReviewRecord)
        /// Doesn't look like schoolwork, so it stayed where it was.
        case leftAlone(UUID, detail: String)
        case duplicate(UUID, detail: String)
        case failed(UUID, String)
    }

    public enum Problem: Error, LocalizedError {
        case notFound
        case unknownSubject

        public var errorDescription: String? {
            switch self {
            case .notFound: "Folio has no record of that file any more."
            case .unknownSubject: "That subject no longer exists."
            }
        }
    }

    /// Where files to sort came from.
    public enum Source: Sendable {
        /// Dropped on Folio or chosen with Add Files.
        case dropped
        /// Arrived in a watched folder, such as Downloads.
        case watched
        /// Handed over by a Shortcut.
        case shortcut
    }

    public struct Options: Sendable {
        public var usesOnDeviceAI = true
        public var model = ModelVoter.Options()
        public var examples = ExampleVoter.Settings()

        public init() {}
    }

    public private(set) var profile: Profile
    /// The student's School folder.
    public let library: URL
    public let store: FolioStore
    public let events: AsyncStream<Event>
    public private(set) var usesOnDeviceAI: Bool

    private let continuation: AsyncStream<Event>.Continuation
    private let organizer: Organizer
    private let pipeline: SortingPipeline
    private let examples: ExampleVoter
    private let timetable = TimetableVoter()
    private let modelVoter: ModelVoter
    private let extractor = Extractor()
    private var listener: Task<Void, Never>?
    /// Files dropped together share a batch in the journal.
    private var batches: [UUID: UUID] = [:]
    /// The first file sorted in each batch with given contents, by hash, so a
    /// copy in the same drop names it even after it's been filed.
    private var namesInBatch: [UUID: [String: String]] = [:]
    /// Files sorted in the background, by ticket.
    private var backgroundTickets: Set<UUID> = []
    /// What files waiting under "Needs a look" say about assessments, offered once they're filed.
    private var readings: [UUID: AssessmentReader.Reading] = [:]
    /// The student's open assessments, so a file that names one can be linked to it.
    private var openAssessments: [Assessment] = []
    /// Files from the last batch that Folio left alone, in case the student wants them sorted anyway.
    private var leftAloneFiles: [UUID: (url: URL, analysis: SortingPipeline.Analysis)] = [:]
    /// Security-scoped URLs Folio is using, by ticket or review entry.
    private var scopedAccess: [UUID: URL] = [:]
    /// What Folio read from files it filed this session, by path in the library,
    /// so the search index needn't read them again.
    private var recentlyRead: [String: (text: String, embedding: TextEmbedder.Embedding?)] = [:]

    public init(library: URL, profile: Profile, store: FolioStore, options: Options = Options()) {
        self.library = library
        self.profile = profile
        self.store = store
        usesOnDeviceAI = options.usesOnDeviceAI
        organizer = Organizer(library: library)
        examples = ExampleVoter(examples: store.examples().map(\.example), settings: options.examples)
        modelVoter = ModelVoter(options: options.model)
        pipeline = SortingPipeline(
            classifier: Self.classifier(model: modelVoter, examples: examples, timetable: timetable, usesAI: options.usesOnDeviceAI),
            examples: examples,
            profile: profile,
            knownHashes: store.knownHashes()
        )
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        listener = Task { [weak self, pipeline] in
            for await event in pipeline.events {
                await self?.handle(event)
            }
        }
    }

    /// Stops listening to the pipeline. Call before replacing the librarian.
    public func shutDown() {
        listener?.cancel()
        listener = nil
        continuation.finish()
        for url in scopedAccess.values {
            url.stopAccessingSecurityScopedResource()
        }
        scopedAccess = [:]
    }

    private static func classifier(model: ModelVoter, examples: ExampleVoter, timetable: TimetableVoter, usesAI: Bool) -> Classifier {
        .standard(model: usesAI ? model : nil, examples: examples, timetable: timetable)
    }

    // MARK: Settings

    public func update(profile: Profile) {
        self.profile = profile
        Task { await pipeline.update(profile: profile) }
    }

    public func setUsesOnDeviceAI(_ usesAI: Bool) {
        usesOnDeviceAI = usesAI
        let classifier = Self.classifier(model: modelVoter, examples: examples, timetable: timetable, usesAI: usesAI)
        Task { await pipeline.update(classifier: classifier) }
    }

    /// The student's assessments, so files that name an open one can be linked to it.
    public func update(assessments: [Assessment]) {
        openAssessments = assessments.filter { !$0.isDone }
    }

    /// The student's classes, for noticing files that arrive during one.
    public func update(classes: [ClassSession]) {
        Task { [timetable] in await timetable.update(classes) }
    }

    /// Claude, when the student has turned it on, for files the other voters
    /// leave for review. `nil` stops asking.
    public func update(secondOpinion: (any Voter)?) {
        Task { [pipeline] in await pipeline.update(secondOpinion: secondOpinion) }
    }

    /// Why the on-device AI isn't helping right now, or `nil` if it is.
    public func aiUnavailableReason() async -> String? {
        guard usesOnDeviceAI else { return "On-device AI is turned off in Folio's settings" }
        return await modelVoter.unavailableReason
    }

    /// Loads the AI model ahead of the first file.
    public func prewarm() async {
        guard usesOnDeviceAI else { return }
        await modelVoter.prewarm(for: profile)
    }

    // MARK: Sorting

    /// Starts sorting and returns a ticket for each file, in order. Folders are
    /// opened up and their files sorted one by one. Progress and results arrive
    /// on `events`.
    ///
    /// Files from watched folders and Shortcuts are sorted in the background:
    /// if nothing in one points to a subject, it's left where it is rather
    /// than added to "Needs a look", because most downloads aren't schoolwork.
    @discardableResult
    public func sort(_ urls: [URL], from source: Source = .dropped) -> [(id: UUID, name: String)] {
        let batch = UUID()
        let unfinished = Set(batches.values)
        namesInBatch = namesInBatch.filter { unfinished.contains($0.key) }
        var jobs: [SortingPipeline.Job] = []
        for url in urls {
            for file in Self.files(in: url, library: library) {
                let job = SortingPipeline.Job(url: file)
                batches[job.id] = batch
                if source != .dropped {
                    backgroundTickets.insert(job.id)
                }
                // Files from the open panel need this; dropped files are already readable.
                if url.startAccessingSecurityScopedResource() {
                    scopedAccess[job.id] = url
                }
                jobs.append(job)
            }
        }
        Task { [pipeline] in await pipeline.enqueue(jobs) }
        return jobs.map { ($0.id, $0.url.lastPathComponent) }
    }

    private func handle(_ event: SortingPipeline.Event) async {
        defer {
            switch event {
            case .analysed(let job, _), .duplicate(let job, _, _), .failed(let job, _): backgroundTickets.remove(job.id)
            case .progress: break
            }
        }
        switch event {
        case .progress(let id, let message):
            continuation.yield(.progress(id, message))
        case .duplicate(let job, let hash, let sameAs):
            let original = sameAs ?? batches.removeValue(forKey: job.id).flatMap { namesInBatch[$0]?[hash] }
            batches[job.id] = nil
            let folder = job.url.deletingLastPathComponent().lastPathComponent
            let detail = original.map { String(localized: "A copy of “\($0)”, so it stayed in \(folder)", bundle: .module) } ?? duplicateDetail(for: hash)
            continuation.yield(.duplicate(job.id, detail: detail))
            endAccess(job.id)
        case .failed(let job, let message):
            batches[job.id] = nil
            continuation.yield(.failed(job.id, message))
            endAccess(job.id)
        case .analysed(let job, let analysis):
            if let batch = batches[job.id], let hash = analysis.contentHash, namesInBatch[batch]?[hash] == nil {
                namesInBatch[batch, default: [:]][hash] = job.url.lastPathComponent
            }
            switch analysis.decision.outcome {
            case .file(let subjectID):
                await autoFile(job, analysis, in: subjectID)
            case .review where backgroundTickets.contains(job.id) && analysis.decision.suggestions.isEmpty:
                batches[job.id] = nil
                forget(analysis.contentHash)
                endAccess(job.id)
                let folder = job.url.deletingLastPathComponent().lastPathComponent
                continuation.yield(.leftAlone(job.id, detail: String(localized: "Nothing in it points to a subject, so it's still in \(folder)", bundle: .module)))
            case .review:
                batches[job.id] = nil
                let record = addToReview(job.url, analysis, ticket: job.id)
                continuation.yield(.needsReview(job.id, record))
            case .notSchoolwork:
                batches[job.id] = nil
                forget(analysis.contentHash)
                leftAloneFiles[job.id] = (job.url, analysis)
                let folder = job.url.deletingLastPathComponent().lastPathComponent
                continuation.yield(.leftAlone(job.id, detail: String(localized: "Doesn't look like schoolwork, so it's still in \(folder)", bundle: .module)))
            }
        }
    }

    private func autoFile(_ job: SortingPipeline.Job, _ analysis: SortingPipeline.Analysis, in subjectID: Subject.ID) async {
        let batch = batches.removeValue(forKey: job.id) ?? UUID()
        guard let subject = profile.subject(subjectID) else {
            continuation.yield(.needsReview(job.id, addToReview(job.url, analysis, ticket: job.id)))
            return
        }
        do {
            let item = try await moveIntoLibrary(
                job.url,
                batch: batch,
                subject: subject,
                facets: analysis.decision.facets,
                contentHash: analysis.contentHash,
                detail: Self.detail(for: analysis),
                reasons: analysis.decision.reasons,
                chosenByStudent: false,
                embedding: analysis.embedding
            )
            endAccess(job.id)
            var filed = record(for: item)
            filed.reading = AssessmentReader.read(analysis.evidence, facets: analysis.decision.facets, open: openAssessments.filter { $0.subjectID == subjectID })
            recentlyRead[item.relativePath] = (Self.searchText(for: analysis.evidence), analysis.embedding)
            continuation.yield(.filed(job.id, filed))
        } catch Organizer.Failure.notAllowed(let folder) {
            continuation.yield(.needsReview(job.id, addToReview(job.url, analysis, ticket: job.id, blockedFolder: folder)))
        } catch {
            forget(analysis.contentHash)
            endAccess(job.id)
            continuation.yield(.failed(job.id, error.localizedDescription))
        }
    }

    /// Puts a file that Folio left alone under "Needs a look" after all.
    public func reviewAnyway(_ ticket: UUID) -> ReviewRecord? {
        guard let (url, analysis) = leftAloneFiles.removeValue(forKey: ticket) else { return nil }
        if let hash = analysis.contentHash {
            Task { [pipeline] in await pipeline.remember(hash) }
        }
        return addToReview(url, analysis, ticket: ticket)
    }

    /// Lets go of the files Folio left alone in earlier batches.
    public func clearLeftAlone() {
        for ticket in leftAloneFiles.keys {
            endAccess(ticket)
        }
        leftAloneFiles = [:]
    }

    // MARK: Needs a look

    /// Files waiting for the student, oldest first.
    public func reviewQueue() -> [ReviewRecord] {
        store.reviewEntries().map { entry in
            _ = currentURL(of: entry)
            return ReviewRecord(entry)
        }
    }

    /// Files a waiting file in the subject the student chose, and learns from it.
    /// Throws `Organizer.Failure.notAllowed` if macOS won't let Folio move it.
    public func file(_ reviewID: ReviewRecord.ID, in subjectID: Subject.ID) async throws -> FiledRecord {
        guard let entry = store.reviewEntry(reviewID) else { throw Problem.notFound }
        guard let subject = profile.subject(subjectID) else { throw Problem.unknownSubject }
        let item = try await moveIntoLibrary(
            currentURL(of: entry),
            batch: UUID(),
            subject: subject,
            facets: entry.facets,
            contentHash: entry.contentHash,
            detail: entry.detail,
            reasons: [String(localized: "You chose \(subject.name)", bundle: .module)],
            chosenByStudent: true,
            embedding: entry.embedding
        )
        let source: LearnedExample.Source = entry.previousSubjectID == nil ? .choice : .correction
        store.delete(entry)
        store.save()
        endAccess(reviewID)
        await learn(from: item, source: source)
        var filed = record(for: item)
        filed.reading = readings.removeValue(forKey: reviewID)
        return filed
    }

    /// Takes a file off "Needs a look" and leaves it where it is.
    public func skip(_ reviewID: ReviewRecord.ID) {
        guard let entry = store.reviewEntry(reviewID) else { return }
        forget(entry.contentHash)
        readings[reviewID] = nil
        store.delete(entry)
        store.save()
        endAccess(reviewID)
    }

    // MARK: Filed files

    /// Filed files, newest first.
    public func recentFiles(limit: Int = 50) -> [FiledRecord] {
        store.filedItems(limit: limit).map(record(for:))
    }

    /// Puts a filed file back where it came from, or into Folio Inbox, and adds
    /// it to "Needs a look" so the student can choose where it should go.
    public func putBack(_ itemID: FiledRecord.ID) async throws -> ReviewRecord {
        guard let item = store.filedItem(itemID) else { throw Problem.notFound }
        let current = url(of: item)
        let original = URL(filePath: item.originalPath)
        let restored = try await organizer.putBack(Organizer.Move(from: original, to: current), from: current)

        item.undoneAt = .now
        store.insert(JournalEntry(batchID: UUID(), action: .putBack, from: current, to: restored.url, itemID: item.id))
        let forgotten = store.deleteExamples(learnedFrom: item.id)

        let folder = original.deletingLastPathComponent().lastPathComponent
        let entry = ReviewEntry(
            name: restored.url.lastPathComponent,
            url: restored.url,
            bookmark: Self.bookmark(for: restored.url),
            question: restored.isOriginalFolder
                ? String(localized: "Moved back to \(folder). Which subject should it go to?", bundle: .module)
                : String(localized: "Folio can't reach \(folder) any more, so it's in Folio Inbox. Which subject should it go to?", bundle: .module),
            suggestions: [],
            reasons: [],
            facets: item.facets,
            contentHash: item.contentHash,
            detail: item.detail,
            embedding: item.embedding,
            previousSubjectID: item.subjectID
        )
        store.insert(entry)
        store.save()
        if !forgotten.isEmpty {
            await examples.removeExamples(forgotten)
        }
        return ReviewRecord(entry)
    }

    // MARK: The library

    /// What's in each subject's folder.
    public func scan() async -> LibrarySnapshot {
        let (library, template, subjects) = (library, FolderTemplate(profile.folderTemplate), profile.subjects)
        return await Blocking.run { LibraryScanner.scan(library, template: template, subjects: subjects) }
    }

    // MARK: Search index

    /// A file in the search index, with where it is.
    public struct IndexedRecord: Sendable {
        public var id: UUID
        /// Inside the library, such as "History/Notes/Weimar.docx".
        public var path: String
        public var url: URL
        public var text: String
        public var embedding: TextEmbedder.Embedding?
    }

    /// Reads every file in the library that isn't in the search index yet, or
    /// that changed since it was read, and forgets files that have gone.
    /// Waits `pause` between files so sorting comes first. Returns how many it read.
    @discardableResult
    public func updateIndex(pause: Duration = .milliseconds(150), progress: (@MainActor (Int, Int) -> Void)? = nil) async -> Int {
        let snapshot = await scan()
        let indexed = Dictionary(store.indexedFiles().map { ($0.path, $0.modified) }, uniquingKeysWith: { first, _ in first })
        let present = Set(snapshot.files.map { relativePath(of: $0.url) })
        store.removeIndexed(Set(indexed.keys).subtracting(present))
        let stale = snapshot.files.filter { file in
            guard let known = indexed[relativePath(of: file.url)] else { return true }
            return known != file.modified
        }
        var read = 0
        for (index, file) in stale.enumerated() {
            if Task.isCancelled { break }
            progress?(index, stale.count)
            let path = relativePath(of: file.url)
            if let recent = recentlyRead.removeValue(forKey: path) {
                store.index(path: path, modified: file.modified, text: recent.text, embedding: recent.embedding)
            } else if let evidence = try? await extractor.extract(from: file.url) {
                store.index(path: path, modified: file.modified, text: Self.searchText(for: evidence), embedding: await examples.embedding(for: evidence))
            } else {
                // Unreadable: index its name, so it isn't tried again until it changes.
                store.index(path: path, modified: file.modified, text: (file.name as NSString).deletingPathExtension, embedding: nil)
            }
            read += 1
            if read % 20 == 0 { store.save() }
            try? await Task.sleep(for: pause)
        }
        store.save()
        progress?(stale.count, stale.count)
        return read
    }

    /// Everything in the search index.
    public func indexedRecords() -> [IndexedRecord] {
        store.indexedFiles().map { record in
            IndexedRecord(id: record.id, path: record.path, url: library.appending(path: record.path, directoryHint: .notDirectory), text: record.text, embedding: record.embedding)
        }
    }

    /// The text kept for searching: the file's name, its title and the start of its text.
    static func searchText(for evidence: Evidence) -> String {
        [evidence.readableFileName, evidence.title, evidence.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Reads much more of a file than sorting does, for flashcards and summaries.
    /// `whole` reads all of it, for Claude writing flashcards.
    public func readThoroughly(_ url: URL, whole: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async throws -> Evidence {
        try await (whole ? Extractor.whole : Extractor.thorough).extract(from: url, progress: progress)
    }

    /// The filed record for a file in the library, if Folio filed it.
    public func filedItemID(at url: URL) -> UUID? {
        let path = relativePath(of: url)
        return store.filedItems().first { $0.relativePath == path }?.id
    }

    /// Facts Folio worked out when it filed files, by path in the library, for past papers.
    public func facetsByPath() -> [String: Facets] {
        Dictionary(store.filedItems().map { ($0.relativePath, $0.facets) }, uniquingKeysWith: { first, _ in first })
    }

    /// The path inside the library of a URL.
    public func pathInLibrary(_ url: URL) -> String {
        relativePath(of: url)
    }

    // MARK: Learning

    public var learnedExampleCount: Int {
        get async { await examples.exampleCount }
    }

    /// Reads up to `perSubject` of the newest files already in each subject's
    /// folder and keeps them as examples, so Folio starts out knowing what the
    /// student's files look like. Files Folio filed on its own are skipped, so
    /// its own guesses don't teach it. Returns how many it learned from.
    @discardableResult
    public func learnFromLibrary(perSubject: Int = 20, progress: (@MainActor (Int, Int) -> Void)? = nil) async -> Int {
        let snapshot = await scan()
        let filedByFolio = Set(store.filedItems().filter { !$0.chosenByStudent }.map(\.relativePath))
        let alreadyKnown = Set(store.examples().map(\.path))
        var chosen: [LibrarySnapshot.File] = []
        for subject in profile.sortableSubjects {
            chosen += snapshot.files
                .filter { $0.subjectID == subject.id }
                .filter { !filedByFolio.contains(relativePath(of: $0.url)) && !alreadyKnown.contains(relativePath(of: $0.url)) }
                .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                .prefix(perSubject)
        }

        var learned = 0
        for (index, file) in chosen.enumerated() {
            if Task.isCancelled { break }
            progress?(index, chosen.count)
            guard let evidence = try? await extractor.extract(from: file.url),
                  let embedding = await examples.embedding(for: evidence)
            else { continue }
            let example = LearnedExample(subjectID: file.subjectID, name: file.name, path: relativePath(of: file.url), embedding: embedding, source: .existing)
            store.insert(example)
            await examples.add(example.example)
            learned += 1
        }
        store.save()
        progress?(chosen.count, chosen.count)
        return learned
    }

    /// Forgets every example, from setup and from the student's choices.
    public func forgetLearning() async {
        store.deleteAllExamples()
        store.save()
        await examples.replaceExamples(with: [])
    }

    private func learn(from item: FiledItem, source: LearnedExample.Source) async {
        var embedding = item.embedding
        if embedding == nil, let evidence = try? await extractor.extract(from: url(of: item)) {
            embedding = await examples.embedding(for: evidence)
        }
        guard let embedding else { return }
        let example = LearnedExample(subjectID: item.subjectID, name: item.name, path: item.relativePath, embedding: embedding, source: source, itemID: item.id)
        store.insert(example)
        store.save()
        await examples.add(example.example)
    }

    // MARK: Moving and recording

    private func moveIntoLibrary(
        _ url: URL,
        batch: UUID,
        subject: Subject,
        facets: Facets,
        contentHash: String?,
        detail: String,
        reasons: [String],
        chosenByStudent: Bool,
        embedding: TextEmbedder.Embedding?
    ) async throws -> FiledItem {
        let folders = FolderTemplate(profile.folderTemplate).folders(for: subject, facets: facets)
        let move = try await organizer.file(url, into: folders)
        let item = FiledItem(
            name: move.to.lastPathComponent,
            subjectID: subject.id,
            relativePath: relativePath(of: move.to),
            originalPath: move.from.path(percentEncoded: false),
            facets: facets,
            contentHash: contentHash,
            detail: detail,
            reasons: reasons,
            chosenByStudent: chosenByStudent,
            bookmark: try? move.to.bookmarkData(),
            embedding: embedding
        )
        store.insert(item)
        store.insert(JournalEntry(batchID: batch, action: .file, from: move.from, to: move.to, itemID: item.id))
        store.save()
        if let contentHash {
            Task { [pipeline] in await pipeline.remember(contentHash) }
        }
        return item
    }

    @discardableResult
    private func addToReview(_ url: URL, _ analysis: SortingPipeline.Analysis, ticket: UUID, blockedFolder: URL? = nil) -> ReviewRecord {
        let decision = analysis.decision
        let entry = ReviewEntry(
            name: url.lastPathComponent,
            url: url,
            bookmark: Self.bookmark(for: url),
            question: question(for: decision, blockedFolder: blockedFolder),
            suggestions: decision.suggestions,
            reasons: decision.reasons,
            facets: decision.facets,
            contentHash: analysis.contentHash,
            detail: Self.detail(for: analysis),
            embedding: analysis.embedding,
            blockedFolder: blockedFolder
        )
        store.insert(entry)
        store.save()
        if let access = scopedAccess.removeValue(forKey: ticket) {
            scopedAccess[entry.id] = access
        }
        readings[entry.id] = AssessmentReader.read(analysis.evidence, facets: decision.facets)
        return ReviewRecord(entry)
    }

    private func question(for decision: Decision, blockedFolder: URL?) -> String {
        if let blockedFolder {
            return String(localized: "Folio needs permission to move files out of \(blockedFolder.lastPathComponent). Choose a subject to try again.", bundle: .module)
        }
        let names = decision.suggestions.compactMap { profile.subject($0)?.name }
        switch names.count {
        case 0: return String(localized: "Which subject should this go to?", bundle: .module)
        case 1: return String(localized: "Looks like \(names[0]), but Folio isn't sure. Where should it go?", bundle: .module)
        default: return String(localized: "Could be \(names[0]) or \(names[1]). Which one should it go to?", bundle: .module)
        }
    }

    private func duplicateDetail(for hash: String) -> String {
        if let item = store.filedItem(withHash: hash) {
            let subject = profile.subject(item.subjectID)?.name ?? String(localized: "your library", bundle: .module)
            let folder = record(for: item).folder
            return String(localized: "Already filed in \([subject, folder].compactMap { $0 }.joined(separator: " · "))", bundle: .module, comment: "Where a copy is filed, such as “Already filed in Physics · Notes”")
        }
        if store.reviewEntries().contains(where: { $0.contentHash == hash }) {
            return String(localized: "Already waiting under Needs a look", bundle: .module)
        }
        return String(localized: "Folio has already sorted a copy of this file", bundle: .module)
    }

    private func record(for item: FiledItem) -> FiledRecord {
        FiledRecord(
            id: item.id,
            name: item.name,
            subjectID: item.subjectID,
            folder: folderBelowSubject(item),
            url: url(of: item),
            filedAt: item.filedAt,
            detail: item.detail,
            reasons: item.reasons,
            chosenByStudent: item.chosenByStudent,
            reading: nil
        )
    }

    /// "Past Papers" for "History/Past Papers/2023.pdf".
    private func folderBelowSubject(_ item: FiledItem) -> String? {
        let parts = item.relativePath.split(separator: "/").map(String.init)
        guard let subject = profile.subject(item.subjectID) else { return nil }
        let subjectFolder = FolderTemplate.cleanFolderName(subject.effectiveFolderName)
        guard let index = parts.firstIndex(where: { $0.caseInsensitiveCompare(subjectFolder) == .orderedSame }),
              index + 1 < parts.count - 1
        else { return nil }
        return parts[index + 1]
    }

    /// Where a filed file is now: found by its bookmark if the student moved it
    /// within the library, otherwise where Folio put it.
    private func url(of item: FiledItem) -> URL {
        if let bookmark = item.bookmark, let url = Self.resolve(bookmark), FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let path = relativePath(of: url)
            if path != item.relativePath, !path.hasPrefix("/") {
                item.relativePath = path
                item.name = url.lastPathComponent
            }
            return url
        }
        return library.appending(path: item.relativePath, directoryHint: .notDirectory)
    }

    /// Where a waiting file is now. Starts security-scoped access when the file
    /// was reached through a bookmark, so Folio can still move it after a restart.
    private func currentURL(of entry: ReviewEntry) -> URL {
        if scopedAccess[entry.id] == nil, let bookmark = entry.bookmark, let url = Self.resolve(bookmark) {
            if url.startAccessingSecurityScopedResource() {
                scopedAccess[entry.id] = url
            }
            if url.path(percentEncoded: false) != entry.path {
                entry.path = url.path(percentEncoded: false)
                entry.name = url.lastPathComponent
            }
            return url
        }
        return entry.url
    }

    private func relativePath(of url: URL) -> String {
        let base = library.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func forget(_ hash: String?) {
        guard let hash else { return }
        Task { [pipeline] in await pipeline.forget(hash) }
    }

    private func endAccess(_ id: UUID) {
        scopedAccess.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    // MARK: Helpers

    /// What Folio worked out about a file, such as "Past Papers · HSC 2023 · 12 pages".
    static func detail(for analysis: SortingPipeline.Analysis) -> String {
        let evidence = analysis.evidence
        let facets = analysis.decision.facets
        var parts: [String] = []
        if let type = facets.documentType { parts.append(type) }
        let exam = [facets.exam, facets.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        if !exam.isEmpty { parts.append(exam) }
        if let pages = evidence.pageCount, pages > 0 {
            parts.append(String(localized: "\(pages) pages", bundle: .module))
        } else if evidence.method == .recognisedText {
            parts.append(String(localized: "text read from the image", bundle: .module))
        } else if evidence.method == .metadataOnly {
            parts.append(String(localized: "sorted by its name", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    /// A bookmark that lets Folio reach the file after a restart: security-scoped
    /// when the sandbox allows it, otherwise a plain one.
    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    static func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return url
        }
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    /// The files to sort from what was dropped: a file as it is, or every file
    /// in a folder (packages such as Keynote documents count as one file).
    /// Hidden files and unfinished downloads are skipped, and so are files
    /// already in the library when the drop includes the whole library.
    static func files(in url: URL, library: URL, limit: Int = 500) -> [URL] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values?.isDirectory == true, values?.isPackage != true else {
            return isUnfinishedDownload(url) ? [] : [url]
        }
        let includesLibrary = isInside(library, url) || Organizer.samePath(library, url)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true { continue }
            if isUnfinishedDownload(file) || (includesLibrary && isInside(file, library)) { continue }
            files.append(file)
            if files.count >= limit { break }
        }
        return files
    }

    /// Whether a file is still downloading, judging by its extension.
    public static func isUnfinishedDownload(_ url: URL) -> Bool {
        ["crdownload", "part", "partial", "download", "opdownload"].contains(url.pathExtension.lowercased())
    }

    /// Whether `url` is somewhere inside `folder`.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).lowercased()
        var base = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).lowercased()
        if !base.hasSuffix("/") { base += "/" }
        return path.hasPrefix(base)
    }
}
