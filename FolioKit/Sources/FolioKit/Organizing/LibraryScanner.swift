import Foundation

/// What's in the library folder, grouped by subject.
public struct LibrarySnapshot: Sendable, Equatable {
    /// A folder inside a subject's folder, such as "History/Past Papers".
    public struct Folder: Hashable, Sendable {
        public var name: String
        public var url: URL
        /// Files in it, including those in folders below it.
        public var fileCount: Int
    }

    public struct File: Hashable, Sendable {
        public var url: URL
        public var subjectID: Subject.ID
        /// The folder below the subject's folder, if the file is in one.
        public var folder: String?
        public var modified: Date?

        public var name: String { url.lastPathComponent }
    }

    public var folders: [Subject.ID: [Folder]] = [:]
    /// Files sitting directly in a subject's folder.
    public var looseFileCounts: [Subject.ID: Int] = [:]
    public var files: [File] = []
    /// Each subject's own folder, such as School/History.
    public var subjectFolders: [Subject.ID: URL] = [:]

    public init() {}

    public func fileCount(of subject: Subject.ID) -> Int {
        (folders[subject] ?? []).reduce(looseFileCounts[subject] ?? 0) { $0 + $1.fileCount }
    }
}

/// Counts the files in each subject's folder by walking the library the way the
/// folder template lays it out. Hidden files are skipped, and packages such as
/// Pages and Keynote documents count as one file.
public enum LibraryScanner {
    public static func scan(_ library: URL, template: FolderTemplate, subjects: [Subject], maxFiles: Int = 50_000) -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        guard let subjectIndex = template.subjectIndex else { return snapshot }

        // Find the folders that match the template's parts before "{subject}".
        var parents = [library]
        for part in template.parts.prefix(subjectIndex) {
            let literal = FolderTemplate.placeholders(in: part).isEmpty ? FolderTemplate.cleanFolderName(part) : nil
            parents = parents.flatMap { parent in
                folders(in: parent).filter { literal == nil || $0.lastPathComponent.caseInsensitiveCompare(literal!) == .orderedSame }
            }
        }

        let subjectsByFolder = Dictionary(
            subjects.map { (FolderTemplate.cleanFolderName($0.effectiveFolderName).lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var budget = maxFiles
        for parent in parents {
            for folder in folders(in: parent) {
                guard let subjectID = subjectsByFolder[folder.lastPathComponent.lowercased()] else { continue }
                if snapshot.subjectFolders[subjectID] == nil {
                    snapshot.subjectFolders[subjectID] = folder
                }
                collect(subjectID, in: folder, into: &snapshot, budget: &budget)
            }
        }
        for (subject, list) in snapshot.folders {
            snapshot.folders[subject] = list.sorted {
                $0.fileCount != $1.fileCount ? $0.fileCount > $1.fileCount : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return snapshot
    }

    private static func collect(_ subject: Subject.ID, in subjectFolder: URL, into snapshot: inout LibrarySnapshot, budget: inout Int) {
        // A subject can have several folders when the template starts with, say, "{year}".
        var counts: [String: (url: URL, count: Int)] = [:]
        for folder in snapshot.folders[subject] ?? [] {
            counts[folder.name] = (folder.url, folder.fileCount)
        }
        // Empty folders are shown too, so a new "Past Papers" folder appears straight away.
        for folder in folders(in: subjectFolder) where counts[folder.lastPathComponent] == nil {
            counts[folder.lastPathComponent] = (folder, 0)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: subjectFolder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        let base = subjectFolder.standardizedFileURL.pathComponents.count

        for case let url as URL in enumerator {
            guard budget > 0 else { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isPackage != true { continue }
            budget -= 1
            let components = Array(url.standardizedFileURL.pathComponents.dropFirst(base))
            let folder = components.count > 1 ? components[0] : nil
            if let folder {
                let existing = counts[folder] ?? (subjectFolder.appending(path: folder, directoryHint: .isDirectory), 0)
                counts[folder] = (existing.url, existing.count + 1)
            } else {
                snapshot.looseFileCounts[subject, default: 0] += 1
            }
            snapshot.files.append(LibrarySnapshot.File(url: url, subjectID: subject, folder: folder, modified: values?.contentModificationDate))
        }
        snapshot.folders[subject] = counts.map { LibrarySnapshot.Folder(name: $0.key, url: $0.value.url, fileCount: $0.value.count) }
    }

    /// Visible folders directly inside `url`, not counting packages.
    static func folders(in url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { child in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
