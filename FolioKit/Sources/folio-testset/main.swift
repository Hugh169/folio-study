import AppKit
import Foundation
import FolioTestSupport

// Builds the labelled test set: one folder per subject (plus "_Unsorted"),
// each holding realistic files rendered from samples.json, and a manifest
// recording what each file should be.
//
// usage: folio-testset <samples.json> <output folder>

struct SampleFile: Decodable {
    let samples: [Sample]
}

struct Sample: Decodable {
    let subject: String
    /// For files that shouldn't be filed: a subject a student might still file it in.
    let related: String?
    let type: String?
    let year: Int?
    let exam: String?
    let tags: [String]
    let file: String
    let format: String
    let title: String?
    let body: String
    /// The voice's language for recordings and videos, such as "fr-FR".
    let language: String?
}

struct ManifestEntry: Encodable {
    let path: String
    let subject: String?
    let related: String?
    let type: String?
    let year: Int?
    let exam: String?
    let tags: [String]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: folio-testset <samples.json> <output folder>")
    exit(64)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let samples = try JSONDecoder().decode(SampleFile.self, from: Data(contentsOf: input)).samples

try? FileManager.default.removeItem(at: output)
var manifest: [ManifestEntry] = []
for (index, sample) in samples.enumerated() {
    let folder = output.appending(path: sample.subject, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: sample.file)
    let seed = UInt64(index + 1)

    switch sample.format {
    case "pdf": try DocumentRenderer.writePDF(title: sample.title, body: sample.body, to: url, seed: seed)
    case "scan": try DocumentRenderer.writePDF(title: sample.title, body: sample.body, to: url, scanned: true, seed: seed)
    case "docx": try DocumentRenderer.writeDocument(title: sample.title, body: sample.body, to: url, as: .officeOpenXML)
    case "rtf": try DocumentRenderer.writeDocument(title: sample.title, body: sample.body, to: url, as: .rtf)
    case "txt": try DocumentRenderer.writePlainText(title: sample.title, body: sample.body, to: url)
    case "photo": try DocumentRenderer.writeHandwrittenPhoto(title: sample.title, body: sample.body, to: url, seed: seed)
    case "recording": try await MediaRenderer.writeRecording(sample.body, to: url, language: sample.language ?? "en-AU")
    case "video": try await MediaRenderer.writeVideo(title: sample.title, body: sample.body, to: url, language: sample.language ?? "en-AU")
    default:
        print("Unknown format “\(sample.format)” for \(sample.file)")
        exit(65)
    }

    manifest.append(ManifestEntry(
        path: "\(sample.subject)/\(sample.file)",
        subject: sample.subject == "_Unsorted" ? nil : sample.subject,
        related: sample.related,
        type: sample.type,
        year: sample.year,
        exam: sample.exam,
        tags: sample.tags
    ))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(manifest).write(to: output.appending(path: "manifest.json"))
print("Wrote \(samples.count) files to \(output.path(percentEncoded: false))")
