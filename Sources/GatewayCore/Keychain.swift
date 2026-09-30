import Foundation
import Security

/// Raw access to the login Keychain (generic passwords under service `TelegramGateway`).
/// Only `KeychainSecretStore` uses it, and only when config.json opts in — see `SecretStore`.
/// Every read of an item another signed identity created prompts for the login password, which is why
/// development binaries and tests never come here.
public enum Keychain {
    public static let service = "TelegramGateway"

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
