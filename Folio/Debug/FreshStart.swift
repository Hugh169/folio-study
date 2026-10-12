#if DEBUG
import Foundation

/// `-FolioFreshStart YES` runs Folio as if it were new, so setup can be tried
/// again and again. It keeps its own profile, records and settings, wiped at
/// every launch, and never touches the real ones or the keychain.
enum FreshStart {
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: "FolioFreshStart")
    }

    private static let defaultsSuite = "FolioFreshStart"

    @MainActor static func makeModel() -> AppModel {
        let support = URL.applicationSupportDirectory.appending(path: "Folio Fresh Start", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: support)
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        return AppModel.live(supportFolder: support, defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard, usesKeychain: false)
    }
}
#endif
