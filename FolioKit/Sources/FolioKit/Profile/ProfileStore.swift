import Foundation

/// Reads and writes the profile as JSON.
public struct ProfileStore: Sendable {
    public enum StoreError: Error, Equatable {
        /// The file was written by a newer version of Folio.
        case newerVersion(Int)
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `profile.json` in Folio's Application Support folder (inside the app's container when sandboxed).
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "Folio/profile.json")
    }

    /// The saved profile, or `nil` if there isn't one yet.
    public func load() throws -> Profile? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
        guard profile.version <= Profile.currentVersion else {
            throw StoreError.newerVersion(profile.version)
        }
        return profile.migrated()
    }

    public func save(_ profile: Profile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(profile).write(to: url, options: .atomic)
    }
}
