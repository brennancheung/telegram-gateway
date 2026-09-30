import Foundation

/// `config.json` in the data directory (docs/api.md "Port and configuration") plus the
/// `TGW_PORT` override. Missing file or fields fall back to the defaults below.
public struct Config: Sendable, Equatable {
    public static let defaultPort = 41414
    public static let defaultMediaCacheMaxBytes: Int64 = 2 * 1024 * 1024 * 1024

    public var port: Int
    /// `nil` keeps every event forever.
    public var eventsRetentionDays: Int?
    public var mediaCacheMaxBytes: Int64
    /// This application's identity with Telegram, from https://my.telegram.org. Both or neither.
    public var apiId: Int32?
    public var apiHash: String?

    public init(
        port: Int = Config.defaultPort,
        eventsRetentionDays: Int? = nil,
        mediaCacheMaxBytes: Int64 = Config.defaultMediaCacheMaxBytes,
        apiId: Int32? = nil,
        apiHash: String? = nil
    ) {
        self.port = port
        self.eventsRetentionDays = eventsRetentionDays
        self.mediaCacheMaxBytes = mediaCacheMaxBytes
        self.apiId = apiId
        self.apiHash = apiHash
    }

    /// True when both `api_id` and `api_hash` are present.
    public var hasCredentials: Bool {
        apiId != nil && !(apiHash ?? "").isEmpty
    }

    /// Reads `paths.config` (absent file → defaults) and applies `TGW_PORT`, `TGW_API_ID`,
    /// `TGW_API_HASH` from the environment.
    public static func load(
        paths: Paths,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Config {
        var config = Config()
        if let data = try? Data(contentsOf: paths.config) {
            let json = try JSONValue.parse(data)
            guard case .object(let fields) = json else {
                throw GatewayError.invalidConfig("\(paths.config.path) is not a JSON object")
            }
            if let port = fields["port"]?.intValue { config.port = port }
            if let retention = fields["events_retention_days"], retention != .null {
                guard let days = retention.intValue else {
                    throw GatewayError.invalidConfig("events_retention_days must be a number or null")
                }
                config.eventsRetentionDays = days
            }
            if let max = fields["media_cache_max_bytes"]?.int64Value { config.mediaCacheMaxBytes = max }
            switch fields["api_id"] {
            case .some(.number(let n)): config.apiId = Int32(exactly: n)
            case .some(.string(let s)): config.apiId = Int32(s)
            default: break
            }
            if let hash = fields["api_hash"]?.stringValue, !hash.isEmpty { config.apiHash = hash }
        }
        if let s = environment["TGW_PORT"], let port = Int(s) { config.port = port }
        if let s = environment["TGW_API_ID"], let id = Int32(s) { config.apiId = id }
        if let s = environment["TGW_API_HASH"], !s.isEmpty { config.apiHash = s }
        return config
    }
}

/// Errors from the gateway's own code paths (not TDLib, not HTTP). `description` is meant for
/// the person at the terminal or the log.
public struct GatewayError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case invalidConfig
        case locked
        case keychain
        case notFound
        case invalid
        case conflict
        case unavailable
    }

    public let kind: Kind
    public let description: String

    public init(_ kind: Kind, _ description: String) {
        self.kind = kind
        self.description = description
    }

    public var errorDescription: String? { description }

    public static func invalidConfig(_ message: String) -> GatewayError { .init(.invalidConfig, message) }
    public static func locked(_ message: String) -> GatewayError { .init(.locked, message) }
    public static func keychain(_ message: String) -> GatewayError { .init(.keychain, message) }
    public static func notFound(_ message: String) -> GatewayError { .init(.notFound, message) }
    public static func invalid(_ message: String) -> GatewayError { .init(.invalid, message) }
    public static func conflict(_ message: String) -> GatewayError { .init(.conflict, message) }
    public static func unavailable(_ message: String) -> GatewayError { .init(.unavailable, message) }
}
