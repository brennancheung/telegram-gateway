import Foundation

/// `~/Library/Application Support/TelegramGateway/config.json`, shared with the daemon and
/// the `tgw` CLI (docs/api.md "Port and configuration", docs/development.md). The app reads
/// it as a whole and writes back by merging, so keys it does not know (`port`,
/// `events_retention_days`, …) survive untouched.
struct GatewayConfig: Sendable, Equatable {
    static let defaultPort = 41414

    /// Telegram `api_id`: the number identifying this software with Telegram.
    var apiId: Int?
    /// Telegram `api_hash`: the 32-hex-character secret paired with `api_id`.
    var apiHash: String?
    var port: Int
    /// Absolute path of the daemon binary the launcher script should exec (development).
    var daemonPath: String?

    var hasCredentials: Bool {
        guard let apiId, apiId > 0, let apiHash else { return false }
        return apiHash.count == 32 && apiHash.allSatisfy(\.isHexDigit)
    }

    /// The daemon's base URL, honouring `TGW_PORT` like the daemon itself does.
    var baseURL: URL {
        let env = ProcessInfo.processInfo.environment
        let effectivePort = env["TGW_PORT"].flatMap(Int.init) ?? port
        return URL(string: "http://127.0.0.1:\(effectivePort)")!
    }

    // MARK: Locations

    /// The data directory: `TGW_HOME` if set, else `~/Library/Application Support/TelegramGateway`.
    static var directory: URL {
        if let home = ProcessInfo.processInfo.environment["TGW_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appending(path: "TelegramGateway", directoryHint: .isDirectory)
    }

    static var fileURL: URL { directory.appending(path: "config.json") }

    /// `~/Library/Logs/TelegramGateway/`, where the launcher and the foreground runner write.
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/TelegramGateway", directoryHint: .isDirectory)
    }

    // MARK: Read and write

    /// Reads the file; a missing file is an empty configuration, a malformed file throws.
    static func load() throws -> GatewayConfig {
        GatewayConfig(raw: try loadRaw())
    }

    init(raw: [String: Any]) {
        switch raw["api_id"] {
        case let number as Int: apiId = number
        case let string as String: apiId = Int(string)
        default: apiId = nil
        }
        apiHash = raw["api_hash"] as? String
        port = raw["port"] as? Int ?? Self.defaultPort
        daemonPath = raw["daemon_path"] as? String
    }

    init(apiId: Int? = nil, apiHash: String? = nil, port: Int = GatewayConfig.defaultPort, daemonPath: String? = nil) {
        self.apiId = apiId
        self.apiHash = apiHash
        self.port = port
        self.daemonPath = daemonPath
    }

    /// Writes `updates` into the file, keeping every other key. Creates the directory and the
    /// file if needed. The file is owner-readable only because it holds `api_hash`.
    @discardableResult
    static func merge(_ updates: [String: Any]) throws -> GatewayConfig {
        var raw = try loadRaw()
        for (key, value) in updates { raw[key] = value }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return GatewayConfig(raw: raw)
    }

    private static func loadRaw() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        return object
    }

    enum ConfigError: Error, LocalizedError {
        case notAnObject
        var errorDescription: String? { "config.json is not a JSON object" }
    }
}
