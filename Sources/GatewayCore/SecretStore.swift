import Foundation
import Synchronization

/// Where the gateway keeps its two secrets: the TDLib database key and the admin token.
///
/// | Implementation | Used by |
/// |---|---|
/// | `FileSecretStore` (`<TGW_HOME>/secrets.json`, mode 0600) | every `swift build` binary (`tgw`, `GatewayDaemon`) by default |
/// | `KeychainSecretStore` (login Keychain) | the shipped, stably-signed menu bar app and daemon, opted in with `"secrets": "keychain"` in config.json |
/// | `MemorySecretStore` | tests |
///
/// Why: an ad-hoc-signed binary is a new identity to the Keychain after every rebuild, so
/// each `SecItemCopyMatching` of an item another build created shows the owner a password
/// prompt. Development therefore never touches the Keychain.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ account: String, _ data: Data) throws
    func delete(_ account: String) throws
    /// Where the secrets live, for messages.
    var description: String { get }
}

public enum SecretsBackend: String, Sendable, Codable {
    case file
    case keychain
}

/// The gateway's secrets on top of any store.
public enum Secrets {
    public static let databaseKeyAccount = "tdlib-db-key"
    public static let adminTokenAccount = "admin-token"

    /// The store `config.json` asks for: `"secrets": "keychain"` → Keychain, else the file.
    public static func resolve(config: Config, paths: Paths) -> any SecretStore {
        switch config.secrets {
        case .keychain: KeychainSecretStore()
        case .file: FileSecretStore(path: paths.secrets)
        }
    }

    /// The database key, generated on first use.
    public static func databaseKey(_ store: any SecretStore) throws -> Data {
        if let existing = try store.read(databaseKeyAccount) {
            guard existing.count == 32 else { throw GatewayError.keychain("\(store.description): \(databaseKeyAccount) is not a 32-byte key") }
            return existing
        }
        let key = Identifiers.randomBytes(32)
        try store.write(databaseKeyAccount, key)
        return key
    }

    /// The admin token, generated on first use.
    public static func adminToken(_ store: any SecretStore) throws -> String {
        if let token = try existingAdminToken(store) { return token }
        return try regenerateAdminToken(store)
    }

    /// The admin token if one exists, without creating it (`tgw` must never mint one).
    public static func existingAdminToken(_ store: any SecretStore) throws -> String? {
        guard let data = try store.read(adminTokenAccount), let token = String(data: data, encoding: .utf8), Identifiers.looksLikeToken(token) else { return nil }
        return token
    }

    /// Replaces the admin token. The old one stops working once the daemon reloads it.
    @discardableResult
    public static func regenerateAdminToken(_ store: any SecretStore) throws -> String {
        let token = Identifiers.token()
        try store.write(adminTokenAccount, Data(token.utf8))
        return token
    }

    /// Copies both secrets from one store to another (e.g. Keychain → file). Returns the
    /// accounts that were copied. Reading the Keychain may prompt the owner; only run this
    /// when they asked for it.
    public static func migrate(from source: any SecretStore, to destination: any SecretStore) throws -> [String] {
        var copied: [String] = []
        for account in [databaseKeyAccount, adminTokenAccount] {
            guard try destination.read(account) == nil, let data = try source.read(account) else { continue }
            try destination.write(account, data)
            copied.append(account)
        }
        return copied
    }
}

/// `secrets.json`: `{ "<account>": "<base64>" }`, owner-readable only, written atomically.
public struct FileSecretStore: SecretStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public var description: String { path.path }

    public func read(_ account: String) throws -> Data? {
        guard let value = try load()[account] else { return nil }
        guard let data = Data(base64Encoded: value) else { throw GatewayError.keychain("\(path.path): \(account) is not base64") }
        return data
    }

    public func write(_ account: String, _ data: Data) throws {
        var all = try load()
        all[account] = data.base64EncodedString()
        try save(all)
    }

    public func delete(_ account: String) throws {
        var all = try load()
        guard all.removeValue(forKey: account) != nil else { return }
        try save(all)
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard case .object(let object) = try JSONValue.parse(data) else { throw GatewayError.keychain("\(path.path) is not a JSON object") }
        var result: [String: String] = [:]
        for (key, value) in object {
            guard let string = value.stringValue else { throw GatewayError.keychain("\(path.path): \(key) is not a string") }
            result[key] = string
        }
        return result
    }

    private func save(_ all: [String: String]) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object = JSONObjectValue()
        for key in all.keys.sorted() { object[key] = .string(all[key] ?? "") }
        let data = JSONValue.object(object).pretty().data(using: .utf8) ?? Data()
        let temporary = path.appendingPathExtension("tmp")
        try data.write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

/// The login Keychain (see `Keychain`). Opt-in; never used by tests.
public struct KeychainSecretStore: SecretStore {
    public init() {}
    public var description: String { "login Keychain, service \(Keychain.service)" }
    public func read(_ account: String) throws -> Data? { try Keychain.read(account: account) }
    public func write(_ account: String, _ data: Data) throws {
        try Keychain.delete(account: account)
        try Keychain.write(account: account, data: data, label: "Telegram Gateway \(account)")
    }
    public func delete(_ account: String) throws { try Keychain.delete(account: account) }
}

/// For tests.
public final class MemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])
    public init() {}
    public var description: String { "memory" }
    public func read(_ account: String) throws -> Data? { items.withLock { $0[account] } }
    public func write(_ account: String, _ data: Data) throws { items.withLock { $0[account] = data } }
    public func delete(_ account: String) throws { items.withLock { _ = $0.removeValue(forKey: account) } }
}
