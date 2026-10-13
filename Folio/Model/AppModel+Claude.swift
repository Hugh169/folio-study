import FolioKit
import SwiftUI

/// How Claude is getting on, for Settings.
enum ClaudeStatus: Equatable {
    /// No key yet, or a key that hasn't been tried this session.
    case unchecked
    case checking
    case ready
    case problem(String)
}

extension AppModel {
    private static let usesClaudeKey = "usesClaude"
    private static let claudeSeesPhotosKey = "claudeSeesPhotos"

    /// Picks up the student's Claude settings. The key itself is read from the
    /// keychain only while Claude is switched on.
    func restoreClaude() {
        guard let live else { return }
        hasClaudeKey = live.keychain?.hasPassword ?? false
        claudeSeesPhotos = live.defaults.bool(forKey: Self.claudeSeesPhotosKey)
        usesClaude = hasClaudeKey && live.defaults.bool(forKey: Self.usesClaudeKey)
        if usesClaude {
            readClaudeKey()
        }
        refreshClaudeUsage()
    }

    /// The key, read from the keychain the first time it's needed: at launch
    /// while Claude sorts files, otherwise when the student first writes
    /// flashcards with it.
    @discardableResult
    func readClaudeKey() -> String? {
        guard let live else { return nil }
        if let key = live.claudeKey { return key }
        do {
            live.claudeKey = try live.keychain?.password()
        } catch {
            claudeStatus = .problem(String(localized: "Folio couldn't read your key from the keychain: \(error.localizedDescription)"))
        }
        return live.claudeKey
    }

    /// Saves a key in the keychain, then checks it with Claude.
    func saveClaudeKey(_ text: String) async {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let live, let keychain = live.keychain, !key.isEmpty else { return }
        do {
            try keychain.save(key)
        } catch {
            claudeStatus = .problem(String(localized: "Couldn't save the key in your keychain: \(error.localizedDescription)"))
            return
        }
        live.claudeKey = key
        hasClaudeKey = true
        await testClaudeKey()
    }

    /// Asks Claude a short question with the saved key.
    func testClaudeKey() async {
        guard let key = readClaudeKey() else { return }
        claudeStatus = .checking
        let problem = await ClaudeVoter.test(key: key)
        claudeStatus = problem.map { .problem($0.message) } ?? .ready
        // A fresh voter, in case the old one stopped asking after a problem that's now fixed.
        updateClaudeVoter()
    }

    func removeClaudeKey() {
        guard let live else { return }
        do {
            try live.keychain?.delete()
        } catch {
            alert = AlertMessage(title: "Couldn't remove the key", detail: error.localizedDescription)
            return
        }
        live.claudeKey = nil
        hasClaudeKey = false
        claudeStatus = .unchecked
        setUsesClaude(false)
    }

    func setUsesClaude(_ on: Bool) {
        usesClaude = on && hasClaudeKey
        live?.defaults.set(usesClaude, forKey: Self.usesClaudeKey)
        if usesClaude {
            readClaudeKey()
        }
        updateClaudeVoter()
    }

    func setClaudeSeesPhotos(_ on: Bool) {
        claudeSeesPhotos = on
        live?.defaults.set(on, forKey: Self.claudeSeesPhotosKey)
        updateClaudeVoter()
    }

    /// Gives the librarian a Claude voter while Claude is on, or takes it away.
    func updateClaudeVoter() {
        guard let live, let librarian = live.librarian else { return }
        guard usesClaude, let key = live.claudeKey else {
            librarian.update(secondOpinion: nil)
            return
        }
        var options = ClaudeVoter.Options()
        options.sendsPhotosBelowTextLength = claudeSeesPhotos ? 40 : nil
        let voter = ClaudeVoter(key: key, options: options, ledger: live.claudeLedger) { [weak self] problem in
            Task { @MainActor in self?.claudeAnswered(problem) }
        }
        librarian.update(secondOpinion: voter)
    }

    private func claudeAnswered(_ problem: ClaudeVoter.Problem?) {
        refreshClaudeUsage()
        switch problem {
        case nil:
            claudeStatus = .ready
        case let problem? where problem.isAboutOneFile:
            break
        case let problem?:
            claudeStatus = .problem(problem.message)
        }
    }

    func refreshClaudeUsage() {
        guard let live else { return }
        claudeUsage = live.claudeLedger.usage()
    }
}
