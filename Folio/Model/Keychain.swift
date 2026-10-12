import Foundation
import Security

/// A password kept in the student's login keychain, such as their Claude API key.
///
/// While Folio is signed to run locally, without a developer team, macOS ties
/// the item to this exact build. A new build that reads it makes macOS ask for
/// the Mac's password once; signing with a team stops that.
struct Keychain {
    let service: String
    let account: String
    /// The name Keychain Access shows.
    let label: String

    /// The student's Anthropic API key.
    static let claudeKey = Keychain(
        service: "\(Bundle.main.bundleIdentifier ?? "Folio").anthropic-api-key",
        account: "Anthropic API key",
        label: "Folio: Claude API key"
    )

    struct Failure: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Whether a password is saved. This doesn't read the password, so macOS never asks.
    var hasPassword: Bool {
        var query = item
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The saved password, or `nil` if there isn't one.
    func password() throws -> String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    func save(_ password: String) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = item
            new[kSecValueData as String] = data
            new[kSecAttrLabel as String] = label
            let added = SecItemAdd(new as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
