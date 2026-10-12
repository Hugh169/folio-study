import AppKit
import FolioKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A curriculum pack shared as a file: subjects, their words and codes, and
    /// kinds of document. The identifier changes with the real bundle ID.
    static let folioPack = UTType(exportedAs: "io.github.hugh169.folio.pack", conformingTo: .json)
}

extension AppModel {
    /// The curriculum pack setup started from.
    var pack: CurriculumPack? {
        profile.packID.flatMap(PackLibrary.pack)
    }

    /// Whether the student already takes a course, by its name.
    func isTaking(_ course: PackSubject) -> Bool {
        subjects.contains { $0.name.caseInsensitiveCompare(course.name) == .orderedSame }
    }

    /// Adds a course from a pack as a subject, with its words and a colour of its own.
    func add(_ course: PackSubject, from pack: CurriculumPack) {
        guard !isTaking(course) else { return }
        let term = profile.level == .university ? subjects.last?.term : nil
        profile.subjects.append(pack.subject(for: course, colorHex: unusedSubjectColour(among: subjects), term: term))
    }

    // MARK: Sharing

    /// Asks for a `.foliopack` file and offers its subjects.
    func chooseAndOpenPack() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a Folio pack to add its subjects.")
        panel.allowedContentTypes = [.folioPack, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openPack(at: url)
    }

    /// Reads a pack someone shared, then offers its subjects to choose from.
    func openPack(at url: URL) {
        guard phase == .ready else {
            alert = AlertMessage(title: "Finish setting up first", message: "Then open the pack again to add its subjects.")
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let pack = try PackLibrary.decode(Data(contentsOf: url))
            let problems = PackLibrary.problems(in: pack, minimumWords: 0)
            guard !pack.subjects.isEmpty, problems.isEmpty else {
                alert = AlertMessage(title: "This pack can't be used", message: "Something in it is missing or repeated, such as two subjects with the same name.")
                return
            }
            openedPack = pack
        } catch {
            alert = AlertMessage(title: "Couldn't open the pack", message: "It isn't a Folio pack, or it's damaged.")
        }
    }

    /// Saves the student's subjects as a pack to share, without their rules or files.
    func exportPack() {
        let panel = NSSavePanel()
        panel.message = String(localized: "Share your subjects, with their words and codes. Your files, rules and name aren't included.")
        panel.allowedContentTypes = [.folioPack]
        let name = pack.map { String(localized: "\($0.name) subjects", comment: "A shared pack's file name, such as “NSW HSC subjects”") } ?? String(localized: "My subjects")
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let shared = PackLibrary.pack(from: profile, name: url.deletingPathExtension().lastPathComponent)
            try PackLibrary.encode(shared).write(to: url, options: .atomic)
        } catch {
            alert = AlertMessage(title: "Couldn't save the pack", detail: error.localizedDescription)
        }
    }
}
