import CryptoKit
import Foundation

enum ContentHash {
    /// A SHA-256 of the file's contents, used to spot files that were already
    /// filed. `nil` for folders and packages such as Pages documents.
    static func sha256(of url: URL) throws -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
