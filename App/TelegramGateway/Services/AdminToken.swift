import Foundation
import Security

/// The admin token (docs/api.md "Authentication"): the one credential that may call
/// `/v1/admin/*`. The daemon generates it on first run and stores it in a **secrets file**,
/// `<TGW_HOME>/secrets.json` (mode 0600, `{"admin-token": "tgw_…"}`); the app only reads it.
///
/// The login Keychain is an opt-in alternative (`"secrets": "keychain"` in `config.json`,
/// service `TelegramGateway`, account `admin-token`) meant for a shipped, stably-signed build.
/// Development builds must not use it: every ad-hoc-signed rebuild is a new identity to the
/// Keychain, so each `SecItem*` read prompts the owner for their password. Nothing in tests,
/// previews or the default development path calls `SecItem*`.
enum AdminToken {
    enum Source: String, Sendable {
        case file
        case keychain
    }

    static let key = "admin-token"
    static let keychainService = "TelegramGateway"

    enum ReadError: Error, LocalizedError {
        case notAnObject(URL)
        case notText
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notAnObject(let url):
                "\(url.path) is not a JSON object"
            case .notText:
                "The stored admin token is not text"
            case .keychain(let status):
                "Keychain read failed: \((SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)")"
            }
        }
    }

    /// The token from the source the configuration selects, or nil when none is stored yet.
    static func read(config: GatewayConfig) throws -> String? {
        switch config.secretsSource {
        case .file: try readFile(at: GatewayConfig.secretsURL)
        case .keychain: try readKeychain()
        }
    }

    /// `secrets.json`: absent file or absent key → nil; malformed file → error.
    static func readFile(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.notAnObject(url)
        }
        guard let value = object[key] else { return nil }
        guard let token = value as? String else { throw ReadError.notText }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Opt-in only (see the type comment). Prompts on every rebuilt ad-hoc binary.
    static func readKeychain() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
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
