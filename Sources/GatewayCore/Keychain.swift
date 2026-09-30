import Foundation
import Security

/// The gateway's secrets in the login Keychain, as generic passwords under service
/// `TelegramGateway`:
///
/// | Account | Holds |
/// |---|---|
/// | `tdlib-db-key` | 32 random bytes TDLib encrypts its database with. Losing it means a fresh login. |
/// | `admin-token` | The one admin token (docs/api.md "Authentication"). The daemon creates it on first run. |
///
/// The daemon runs as a LaunchAgent (the owner's user), which is what makes the login
/// Keychain reachable.
public enum Keychain {
    public static let service = "TelegramGateway"
    public static let databaseKeyAccount = "tdlib-db-key"
    public static let adminTokenAccount = "admin-token"

    /// The database key, generated on first use.
    public static func databaseKey() throws -> Data {
        if let existing = try read(account: databaseKeyAccount) {
            guard existing.count == 32 else {
                throw GatewayError.keychain("Keychain item \(service)/\(databaseKeyAccount) is not a 32-byte key")
            }
            return existing
        }
        let key = Identifiers.randomBytes(32)
        try write(account: databaseKeyAccount, data: key, label: "Telegram Gateway TDLib database key")
        return key
    }

    /// The admin token, generated on first use.
    public static func adminToken() throws -> String {
        if let existing = try read(account: adminTokenAccount), let token = String(data: existing, encoding: .utf8) {
            return token
        }
        return try regenerateAdminToken()
    }

    /// The admin token if one exists, without creating it (for `tgw`, which must never mint one).
    public static func existingAdminToken() throws -> String? {
        guard let data = try read(account: adminTokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the admin token. The old one stops working once the daemon reloads it.
    @discardableResult
    public static func regenerateAdminToken() throws -> String {
        let token = Identifiers.token()
        try delete(account: adminTokenAccount)
        try write(account: adminTokenAccount, data: Data(token.utf8), label: "Telegram Gateway admin token")
        return token
    }

    // MARK: Generic access

    public static func read(account: String) throws -> Data? {
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
            guard let data = item as? Data else {
                throw GatewayError.keychain("Keychain item \(service)/\(account) has no data")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw GatewayError.keychain("Keychain read failed: \(message(for: status))")
        }
    }

    public static func write(account: String, data: Data, label: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GatewayError.keychain("Keychain write failed: \(message(for: status))")
        }
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayError.keychain("Keychain delete failed: \(message(for: status))")
        }
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
