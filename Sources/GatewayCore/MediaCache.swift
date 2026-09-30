import Foundation
import Logging
import TDLibClient

/// On-demand media (docs/api.md "Media"): downloads a file through TDLib on first request,
/// serves it from TDLib's `files/` directory afterwards, and evicts least-recently-served
/// files once the cache exceeds the configured size. The index lives in the store.
public actor MediaCache {
    public enum Fetch: Sendable, Equatable {
        /// The file is on disk.
        case ready(path: String, bytes: Int64)
        /// Still downloading after the wait; poll again.
        case downloading(bytesDownloaded: Int64, size: Int64?)
    }

    private let store: Store
    private let tdlib: any TDLibRequesting
    private let clock: any GatewayClock
    private let logger: Logger
    public private(set) var maxBytes: Int64

    public init(store: Store, tdlib: any TDLibRequesting, maxBytes: Int64, clock: any GatewayClock = SystemClock(), logger: Logger = Logger(label: "media")) {
        self.store = store
        self.tdlib = tdlib
        self.maxBytes = maxBytes
        self.clock = clock
        self.logger = logger
    }

    /// The index record, or nil for an unknown media id.
    public func record(_ mediaId: String) async throws -> MediaRecord? {
        try await store.media(mediaId)
    }

    /// Whether the bytes are on disk right now (`HEAD` reports it without downloading).
    public func isCached(_ mediaId: String) async throws -> Bool {
        guard let record = try await store.media(mediaId), let path = record.localPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Serves from disk, or starts the download and waits up to `wait` for it. Throws
    /// `media_gone` when Telegram cannot provide the file any more.
    public func fetch(_ mediaId: String, wait: Duration = .seconds(30)) async throws -> Fetch {
        guard let record = try await store.media(mediaId) else { throw APIError.notFound }
        if let path = record.localPath, FileManager.default.fileExists(atPath: path) {
            try await store.setMediaServed(mediaId, at: clock.now)
            return .ready(path: path, bytes: record.cachedBytes)
        }
        let file: JSONObject
        do {
            file = try await tdlib.request("getRemoteFile", ["remote_file_id": record.remoteId]).object
        } catch let error as TDLibError {
            if error.code == 400 || error.code == 404 { throw APIError.mediaGone(mediaId) }
            throw error
        }
        guard let fileId = file.int("id") else { throw APIError.mediaGone(mediaId) }
        if let local = file.object("local"), local.bool("is_downloading_completed") == true, let path = local.string("path"), !path.isEmpty {
            return try await cached(mediaId, path: path, bytes: local.int64("downloaded_size") ?? 0)
        }

        // Start (or continue) the download and poll TDLib for completion until `wait` has
        // passed on the clock. The download keeps going after we answer 202.
        _ = try await tdlib.request("downloadFile", ["file_id": fileId, "priority": 1, "offset": 0, "limit": 0, "synchronous": false])
        let started = clock.now
        var progress: JSONObject = file
        while true {
            progress = (try? await tdlib.request("getFile", ["file_id": fileId]).object) ?? progress
            if let local = progress.object("local"), local.bool("is_downloading_completed") == true, let path = local.string("path"), !path.isEmpty {
                return try await cached(mediaId, path: path, bytes: local.int64("downloaded_size") ?? 0)
            }
            if clock.now.timeIntervalSince(started) >= Double(wait.components.seconds) { break }
            try await clock.sleep(for: .milliseconds(250))
        }
        let local = progress.object("local")
        let size = progress.int64("size").flatMap { $0 > 0 ? $0 : nil } ?? progress.int64("expected_size").flatMap { $0 > 0 ? $0 : nil }
        return .downloading(bytesDownloaded: local?.int64("downloaded_size") ?? 0, size: size ?? record.media.size)
    }

    private func cached(_ mediaId: String, path: String, bytes: Int64) async throws -> Fetch {
        let size = bytes > 0 ? bytes : (Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0))
        try await store.setMediaCached(mediaId, localPath: path, bytes: size, servedAt: clock.now)
        try await evictIfNeeded(keeping: mediaId)
        return .ready(path: path, bytes: size)
    }

    /// Evicts least-recently-served files until the cache fits `maxBytes`.
    public func evictIfNeeded(keeping: String? = nil) async throws {
        var total = try await store.cachedMediaBytes()
        guard total > maxBytes else { return }
        for record in try await store.cachedMedia() where record.media.mediaId != keeping {
            if total <= maxBytes { break }
            await evict(record)
            total -= record.cachedBytes
        }
    }

    private func evict(_ record: MediaRecord) async {
        // Ask TDLib to delete its copy (it knows the file id); fall back to removing the path.
        if let file = try? await tdlib.request("getRemoteFile", ["remote_file_id": record.remoteId]).object, let fileId = file.int("id") {
            _ = try? await tdlib.request("deleteFile", ["file_id": fileId])
        }
        if let path = record.localPath, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? await store.setMediaCached(record.media.mediaId, localPath: nil, bytes: 0, servedAt: nil)
        logger.debug("evicted \(record.media.mediaId) (\(record.cachedBytes) bytes)")
    }

    public func cachedBytes() async throws -> Int64 {
        try await store.cachedMediaBytes()
    }
}
