import Foundation

/// What each test file should be, from folio-testset's manifest.json.
struct Label: Decodable {
    let path: String
    let subject: String?
    /// For a file that shouldn't be filed, a subject a student might still
    /// file it in, such as Music for a guitar chord chart.
    let related: String?
    let type: String?
    let year: Int?
    let exam: String?
    let tags: [String]
}

enum Manifest {
    static let unsortedFolder = "_Unsorted"

    /// Labels keyed by path relative to the test folder. Empty when there's no manifest.
    static func load(from folder: URL) -> [String: Label] {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let labels = try? JSONDecoder().decode([Label].self, from: data)
        else { return [:] }
        return Dictionary(labels.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every file under the folder except the manifest and hidden files, in a stable order.
    static func files(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.lastPathComponent != "manifest.json"
            else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Without a manifest, the subject is the name of the file's top-level folder.
    static func subject(fromFolderOf relativePath: String) -> String? {
        guard let folder = relativePath.split(separator: "/").first.map(String.init), folder != unsortedFolder else { return nil }
        return folder
    }

    /// Every file in the test folders with its label. Paths start with the
    /// folder's name when there's more than one folder.
    static func testFiles(in folders: [URL]) -> [TestFile] {
        folders.flatMap { folder in
            let labels = load(from: folder)
            let base = folder.path(percentEncoded: false)
            return files(in: folder).map { url in
                let relative = String(url.path(percentEncoded: false).dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let label = labels[relative]
                return TestFile(
                    url: url,
                    path: folders.count > 1 ? "\(folder.lastPathComponent)/\(relative)" : relative,
                    label: label,
                    subject: label?.subject ?? subject(fromFolderOf: relative)
                )
            }
        }
    }
}

/// A file to sort, and what it should be.
struct TestFile {
    let url: URL
    let path: String
    let label: Label?
    /// The subject it belongs to, as labelled, or nil when it shouldn't be filed.
    let subject: String?
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
