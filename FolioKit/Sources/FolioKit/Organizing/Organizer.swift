import Foundation

/// Moves files into the library and back out again. It never replaces or
/// deletes anything: when a name is taken it adds " 2", " 3" and so on.
public struct Organizer: Sendable {
    /// The folder inside the library for files that can't go back where they came from.
    public static let inboxFolderName = "Folio Inbox"

    public struct Move: Hashable, Codable, Sendable {
        public var from: URL
        public var to: URL

        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    /// Where a file ended up after being put back.
    public struct Restored: Hashable, Sendable {
        public var url: URL
        /// Whether it went back to the folder it came from, rather than Folio Inbox.
        public var isOriginalFolder: Bool
    }

    public enum Failure: Error, Hashable, LocalizedError {
        /// macOS didn't let Folio move files out of this folder.
        case notAllowed(folder: URL)
        /// The file wasn't where Folio expected it.
        case missing(URL)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notAllowed(let folder): String(localized: "Folio isn't allowed to move files out of “\(folder.lastPathComponent)”.", bundle: .module)
            case .missing(let url): String(localized: "Couldn't find “\(url.lastPathComponent)”. It may have been moved or deleted.", bundle: .module)
            case .failed(let message): message
            }
        }
    }

    /// The student's School folder.
    public let library: URL

    public init(library: URL) {
        self.library = library
    }

    public func url(for folders: [String]) -> URL {
        folders.reduce(library) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    public var inbox: URL {
        library.appending(path: Self.inboxFolderName, directoryHint: .isDirectory)
    }

    /// Moves `file` into `folders` inside the library, creating them as needed.
    /// A file that's already there stays put.
    public func file(_ file: URL, into folders: [String]) async throws -> Move {
        let folder = url(for: folders)
        if Self.samePath(file.deletingLastPathComponent(), folder) {
            return Move(from: file, to: file)
        }
        return try await move(file, into: folder, name: file.lastPathComponent)
    }

    /// Puts a filed file back in the folder it came from, or into Folio Inbox
    /// if that folder is gone or Folio can no longer reach it.
    public func putBack(_ move: Move, from current: URL? = nil) async throws -> Restored {
        let source = current ?? move.to
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw Failure.missing(source)
        }
        let original = move.from.deletingLastPathComponent()
        let name = move.from.lastPathComponent
        if Self.isFolder(original) {
            do {
                let back = try await self.move(source, into: original, name: name, createsFolder: false)
                return Restored(url: back.to, isOriginalFolder: true)
            } catch Failure.notAllowed {
                // Folio's access to that folder ended with the last session; use the inbox.
            }
        }
        let parked = try await self.move(source, into: inbox, name: name)
        return Restored(url: parked.to, isOriginalFolder: false)
    }

    // MARK: Moving

    private func move(_ file: URL, into folder: URL, name: String, createsFolder: Bool = true) async throws -> Move {
        try await Blocking.run {
            try Self.moveNow(file, into: folder, name: name, createsFolder: createsFolder)
        }
    }

    private static func moveNow(_ file: URL, into folder: URL, name: String, createsFolder: Bool) throws -> Move {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path(percentEncoded: false)) else { throw Failure.missing(file) }
        if createsFolder {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw failure(for: error, file: file, folder: folder)
            }
        }

        for attempt in 1...100 {
            let destination = folder.appending(path: numbered(name, attempt), directoryHint: .notDirectory)
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) { continue }

            // Coordinating tells other apps with the file open, and iCloud, that it's moving.
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var moveError: (any Error)?
            coordinator.coordinate(writingItemAt: file, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &coordinationError) { source, target in
                do {
                    coordinator.item(at: source, willMoveTo: target)
                    try manager.moveItem(at: source, to: target)
                    coordinator.item(at: source, didMoveTo: target)
                } catch {
                    moveError = error
                }
            }
            guard let error = moveError ?? coordinationError else {
                return Move(from: file, to: destination)
            }
            // Something else took the name in the meantime: try the next one.
            if (error as? CocoaError)?.code == .fileWriteFileExists { continue }
            throw failure(for: error, file: file, folder: file.deletingLastPathComponent())
        }
        throw Failure.failed("There are too many files called “\(name)” in “\(folder.lastPathComponent)”.")
    }

    /// "Notes.pdf", then "Notes 2.pdf", "Notes 3.pdf"…
    static func numbered(_ name: String, _ attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(ext)"
    }

    /// Turns a file system error into a `Failure`. A permission error is blamed
    /// on `folder`: the library for creating folders, the source when moving.
    private static func failure(for error: any Error, file: URL, folder: URL) -> Failure {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let denied = (error.domain == NSCocoaErrorDomain && [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code))
            || (underlying?.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(underlying?.code ?? 0))
        if denied { return .notAllowed(folder: folder) }
        if error.domain == NSCocoaErrorDomain, [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code) {
            return .missing(file)
        }
        return .failed(error.localizedDescription)
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == b.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Runs blocking file work on a background queue, so a slow copy between
/// drives doesn't hold up Swift's shared threads.
enum Blocking {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
