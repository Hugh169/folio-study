import Foundation

enum FileMetadata {
    /// The extended attribute browsers and other apps use to record where a download came from.
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    /// The extended attribute browsers use to record when a file was downloaded.
    static let downloadedDateAttribute = "com.apple.metadata:kMDItemDownloadedDate"

    /// When the file was downloaded, as the browser recorded it.
    static func downloadedDate(of url: URL) -> Date? {
        url.withUnsafeFileSystemRepresentation { path -> Date? in
            guard let path else { return nil }
            let size = getxattr(path, downloadedDateAttribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, downloadedDateAttribute, $0.baseAddress, size, 0, 0) }
            guard read == size, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Date] else { return nil }
            return list.first
        }
    }

    /// The web addresses macOS recorded when the file was downloaded, if any.
    static func downloadSources(of url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = getxattr(path, whereFromsAttribute, nil, 0, 0, 0)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, whereFromsAttribute, $0.baseAddress, size, 0, 0) }
            guard read == size,
                  let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
            else { return [] }
            return list.filter { !$0.isEmpty }
        }
    }
}
