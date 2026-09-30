import Foundation

/// Where the gateway keeps its data: `~/Library/Application Support/TelegramGateway/`.
enum Paths {
    static var root: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appending(path: "TelegramGateway", directoryHint: .isDirectory)
    }

    /// TDLib's own directory: `td.binlog`, `db.sqlite`, and `files/` for downloads. Only one
    /// process may open it at a time.
    static var tdlib: URL { root.appending(path: "tdlib", directoryHint: .isDirectory) }
    static var tdlibFiles: URL { tdlib.appending(path: "files", directoryHint: .isDirectory) }

    /// Optional `{"api_id": …, "api_hash": "…"}` fallback for the credentials.
    static var config: URL { root.appending(path: "config.json") }

    /// Creates the data directories if they do not exist.
    static func prepare() throws {
        try FileManager.default.createDirectory(at: tdlibFiles, withIntermediateDirectories: true)
    }
}
