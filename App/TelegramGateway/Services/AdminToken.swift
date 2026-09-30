import Foundation
import Security

/// The admin token the daemon writes to the login Keychain on first run (docs/api.md
/// "Authentication"): a generic password with service `TelegramGateway` and account
/// `admin-token`. The app only reads it. The first read after each rebuild may show a
/// Keychain prompt because the ad-hoc-signed app is a new "application" each time; the
/// owner clicks Always Allow (docs/app.md "Troubleshooting").
enum AdminToken {
    static let service = "TelegramGateway"
    static let account = "admin-token"

    enum ReadError: Error, LocalizedError {
        case keychain(OSStatus)
        case notText

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                "Keychain read failed: \((SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)")"
            case .notText:
                "The Keychain item \(service)/\(account) is not a text token"
            }
        }
    }

    /// The token, or nil when the daemon has not written one yet.
    static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else { throw ReadError.notText }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw ReadError.keychain(status)
        }
    }
}
