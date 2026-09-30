import Foundation
import Security

/// The key TDLib encrypts its database with. Generated once (32 random bytes) and kept in the
/// login Keychain as a generic password: service "TelegramGateway", account "tdlib-db-key".
/// Losing it means the local database is unreadable and a fresh login is needed.
enum Keychain {
    static let service = "TelegramGateway"
    static let account = "tdlib-db-key"

    static func databaseKey() throws -> Data {
        if let existing = try read() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CLIError("could not generate random bytes: \(status)")
        }
        let key = Data(bytes)
        try write(key)
        return key
    }

    private static func read() throws -> Data? {
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
            guard let data = item as? Data, data.count == 32 else {
                throw CLIError("Keychain item \(service)/\(account) is not a 32-byte key")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CLIError("Keychain read failed: \(message(for: status))")
        }
    }

    private static func write(_ key: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Telegram Gateway TDLib database key",
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CLIError("Keychain write failed: \(message(for: status))")
        }
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
