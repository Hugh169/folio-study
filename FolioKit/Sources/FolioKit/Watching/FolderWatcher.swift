import Foundation

/// Watches folders, such as Downloads, and reports each new file once it has
/// finished arriving. Files already there when watching starts are left alone,
/// unless they arrived after `since`, which covers files downloaded while Folio
/// wasn't running. Hidden files, folders and unfinished downloads are skipped.
public actor FolderWatcher {
    public struct Arrival: Hashable, Sendable {
        public let file: URL
        /// The watched folder it arrived in.
        public let folder: URL
    }

    public nonisolated let arrivals: AsyncStream<Arrival>
    private let continuation: AsyncStream<Arrival>.Continuation

    /// How often a new file is checked while it's still being written.
    private let checkInterval: Duration
    private var watches: [URL: Watch] = [:]
    private var settling: Set<URL> = []
    /// Files Folio itself is about to put in a watched folder, such as on Undo.
    private var ignored: [String: ContinuousClock.Instant] = [:]

    private final class Watch: @unchecked Sendable {
        let source: DispatchSourceFileSystemObject
        var known: Set<String>

        init(source: DispatchSourceFileSystemObject, known: Set<String>) {
            self.source = source
            self.known = known
        }
    }

    public init(checkInterval: Duration = .seconds(1)) {
        (arrivals, continuation) = AsyncStream.makeStream(of: Arrival.self)
        self.checkInterval = checkInterval
    }

    deinit {
        for watch in watches.values {
            watch.source.cancel()
        }
        continuation.finish()
    }

    public var watchedFolders: [URL] {
        Array(watches.keys)
    }

    /// Watches these folders, and stops watching any others. For each folder,
    /// files added after its date are reported as if they'd just arrived.
    public func watch(_ folders: [URL: Date?]) {
        let wanted = Dictionary(folders.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        for (folder, watch) in watches where wanted[folder] == nil {
            watch.source.cancel()
            watches[folder] = nil
        }
        for (folder, since) in wanted where watches[folder] == nil {
            start(folder, since: since)
        }
    }

    public func stop() {
        watch([:])
    }

    /// Don't report this file if it turns up in a watched folder soon, because
    /// Folio is putting it there itself.
    public func ignore(_ file: URL) {
        ignored[Self.key(file).path(percentEncoded: false)] = .now + .seconds(120)
    }

    // MARK: Watching

    private func start(_ folder: URL, since: Date?) {
        let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.folderChanged(folder) }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        let entries = Self.entries(in: folder)
        // Files that arrived while Folio wasn't watching still count as new.
        let missed = since.map { since in entries.filter { name in (Self.dateAdded(folder.appending(path: name)) ?? .distantPast) > since } } ?? []
        watches[folder] = Watch(source: source, known: entries.subtracting(missed))
        source.resume()
        folderChanged(folder)
    }

    private func folderChanged(_ folder: URL) {
        guard let watch = watches[folder] else { return }
        let entries = Self.entries(in: folder)
        let added = entries.subtracting(watch.known)
        watch.known = entries
        for name in added.sorted() {
            let file = folder.appending(path: name)
            guard !settling.contains(file) else { continue }
            settling.insert(file)
            Task { await settle(file, in: folder) }
        }
    }

    /// Waits until a new file has stopped changing, then reports it.
    private func settle(_ file: URL, in folder: URL) async {
        defer { settling.remove(file) }
        var last: (size: Int, modified: Date)?
        for _ in 0..<3600 {
            try? await Task.sleep(for: checkInterval)
            guard watches[folder] != nil, let state = Self.state(of: file) else { return }
            if state.isFolder { return }
            if Self.isUnfinishedDownload(file) || state.size == 0 || Self.hasUnfinishedPartner(file) {
                last = nil
                continue
            }
            if let last, last.size == state.size, last.modified == state.modified {
                if let until = ignored.removeValue(forKey: file.path(percentEncoded: false)), until > .now { return }
                continuation.yield(Arrival(file: file, folder: folder))
                return
            }
            last = (state.size, state.modified)
        }
    }

    // MARK: Files

    private static func key(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Visible names in a folder.
    private static func entries(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    private static func state(of file: URL) -> (size: Int, modified: Date, isFolder: Bool)? {
        var url = file
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isPackageKey]) else {
            return nil
        }
        let isFolder = values.isDirectory == true && values.isPackage != true
        let size = values.fileSize ?? values.totalFileSize ?? (values.isPackage == true ? 1 : 0)
        return (size, values.contentModificationDate ?? .distantPast, isFolder)
    }

    private static func dateAdded(_ file: URL) -> Date? {
        let values = try? file.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }

    static func isUnfinishedDownload(_ url: URL) -> Bool {
        ["crdownload", "part", "partial", "download", "opdownload", "tmp"].contains(url.pathExtension.lowercased())
    }

    /// Firefox saves "paper.pdf" straight away and fills "paper.pdf.part"; the
    /// file is only finished when the partner is gone.
    private static func hasUnfinishedPartner(_ url: URL) -> Bool {
        ["part", "crdownload", "download"].contains { ext in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false) + "." + ext)
        }
    }
}
