import Foundation
import Testing
@testable import FolioKit

/// Collects a watcher's arrivals so tests can wait for them.
actor ArrivalLog {
    private(set) var files: [String] = []
    private var task: Task<Void, Never>?

    init(_ watcher: FolderWatcher) {
        let arrivals = watcher.arrivals
        Task { await self.start(arrivals) }
    }

    private func start(_ arrivals: AsyncStream<FolderWatcher.Arrival>) {
        task = Task {
            for await arrival in arrivals {
                record(arrival.file.lastPathComponent)
            }
        }
    }

    private func record(_ name: String) {
        files.append(name)
    }

    /// Waits up to `seconds` for `name` to arrive.
    func wait(for name: String, seconds: Double = 5) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if files.contains(name) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return files.contains(name)
    }
}

struct FolderWatcherTests {
    func watcher(_ folder: URL, since: Date? = nil) async -> (FolderWatcher, ArrivalLog) {
        let watcher = FolderWatcher(checkInterval: .milliseconds(100))
        let log = ArrivalLog(watcher)
        await watcher.watch([folder: since])
        return (watcher, log)
    }

    @Test func reportsANewFileOnceItsWritten() async throws {
        let temp = try TemporaryFolder()
        let downloads = try temp.folder("Downloads")
        let (watcher, log) = await watcher(downloads)

        try temp.file("Downloads/2023-hsc-modern-history-exam.pdf", contents: "paper")

        #expect(await log.wait(for: "2023-hsc-modern-history-exam.pdf"))
        _ = watcher
    }

    @Test func filesAlreadyThereAreLeftAlone() async throws {
        let temp = try TemporaryFolder()
        try temp.file("Downloads/old receipt.pdf")
        let (watcher, log) = await watcher(temp.url.appending(path: "Downloads"))

        try temp.file("Downloads/new.pdf")

        #expect(await log.wait(for: "new.pdf"))
        #expect(await log.files == ["new.pdf"])
        _ = watcher
    }

    @Test func waitsForChromeDownloadsToFinish() async throws {
        let temp = try TemporaryFolder()
        let downloads = try temp.folder("Downloads")
        let (watcher, log) = await watcher(downloads)

        let partial = try temp.file("Downloads/paper.pdf.crdownload", contents: "half")
        try await Task.sleep(for: .milliseconds(600))
        #expect(await log.files.isEmpty)
        try FileManager.default.moveItem(at: partial, to: downloads.appending(path: "paper.pdf"))

        #expect(await log.wait(for: "paper.pdf"))
        #expect(await log.files == ["paper.pdf"])
        _ = watcher
    }

    @Test func waitsForFirefoxDownloadsToFinish() async throws {
        let temp = try TemporaryFolder()
        let downloads = try temp.folder("Downloads")
        let (watcher, log) = await watcher(downloads)

        // Firefox makes an empty file straight away and downloads into a ".part" partner.
        let file = try temp.file("Downloads/notes.pdf", contents: "")
        let partner = try temp.file("Downloads/notes.pdf.part", contents: "downloading")
        try await Task.sleep(for: .milliseconds(600))
        #expect(await log.files.isEmpty)
        try Data("finished".utf8).write(to: file)
        try FileManager.default.removeItem(at: partner)

        #expect(await log.wait(for: "notes.pdf"))
        _ = watcher
    }

    @Test func filesFolioPutsBackAreIgnored() async throws {
        let temp = try TemporaryFolder()
        let downloads = try temp.folder("Downloads")
        let (watcher, log) = await watcher(downloads)

        await watcher.ignore(downloads.appending(path: "put back.pdf"))
        try temp.file("Downloads/put back.pdf")
        try temp.file("Downloads/other.pdf")

        #expect(await log.wait(for: "other.pdf"))
        #expect(await !log.files.contains("put back.pdf"))
    }

    @Test func filesDownloadedWhileFolioWasClosedStillCount() async throws {
        let temp = try TemporaryFolder()
        try temp.file("Downloads/before.pdf")
        let downloads = temp.url.appending(path: "Downloads")

        let (watcher, log) = await watcher(downloads, since: .now.addingTimeInterval(-60))

        #expect(await log.wait(for: "before.pdf"))
        _ = watcher
    }

    @Test func foldersAreSkipped() async throws {
        let temp = try TemporaryFolder()
        let downloads = try temp.folder("Downloads")
        let (watcher, log) = await watcher(downloads)

        _ = try temp.folder("Downloads/Unzipped notes")
        try temp.file("Downloads/after.pdf")

        #expect(await log.wait(for: "after.pdf"))
        #expect(await log.files == ["after.pdf"])
        _ = watcher
    }
}
