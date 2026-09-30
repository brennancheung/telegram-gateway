import Foundation

/// Where the gateway keeps its data. Default `~/Library/Application Support/TelegramGateway/`;
/// the `TGW_HOME` environment variable overrides it (development: a second gateway).
///
/// ```
/// <home>/
///   config.json      port, retention, media cache size, api_id / api_hash
///   gateway.sqlite   the gateway's store (monitored chats, grants, event log, cursors)
///   tdlib/           TDLib's own directory (td.binlog, db.sqlite, files/)
///   logs/            launchd stdout/stderr
///   daemon.lock      held (flock) by whichever process owns TDLib
///   secrets.json     TDLib database key and admin token (file secret store, mode 0600)
/// ```
public struct Paths: Sendable, Equatable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// `TGW_HOME` from the environment, else the default under Application Support.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let custom = environment["TGW_HOME"], !custom.isEmpty {
            return Paths(home: URL(filePath: custom, directoryHint: .isDirectory))
        }
        return Paths(home: defaultHome)
    }

    public static var defaultHome: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appending(path: "TelegramGateway", directoryHint: .isDirectory)
    }

    /// TDLib's own directory: `td.binlog`, `db.sqlite`, and `files/` for downloads. Only one
    /// process may open it at a time.
    public var tdlib: URL { home.appending(path: "tdlib", directoryHint: .isDirectory) }
    public var tdlibFiles: URL { tdlib.appending(path: "files", directoryHint: .isDirectory) }
    public var config: URL { home.appending(path: "config.json") }
    public var database: URL { home.appending(path: "gateway.sqlite") }
    public var logs: URL { home.appending(path: "logs", directoryHint: .isDirectory) }
    public var lock: URL { home.appending(path: "daemon.lock") }
    /// The file secret store (docs/development.md "Secrets").
    public var secrets: URL { home.appending(path: "secrets.json") }

    /// Creates the data directories if they do not exist.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: tdlibFiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }
}
