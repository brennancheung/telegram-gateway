import Foundation

/// Housekeeping shared by the admin endpoint and the daemon's hourly job.
public enum Maintenance {
    /// Deletes events below `boundary` (docs/api.md "Admin: pruning"). Refuses with
    /// `409 cursor_behind` when a webhook cursor is behind the boundary unless `force`, in
    /// which case that cursor moves to the new oldest `seq`.
    public static func pruneEvents(boundary: Int64, force: Bool, eventLog: EventLog, grants: Grants) async throws -> (deleted: Int, oldestSeq: Int64) {
        for grant in try await grants.grantsWithWebhooks() {
            guard let webhook = grant.webhook, webhook.cursorSeq + 1 < boundary else { continue }
            guard force else { throw APIError.cursorBehind(grantId: grant.id) }
            try await grants.updateWebhook(grantId: grant.id) {
                $0.cursorSeq = boundary - 1
                $0.lastError = "events pruned; cursor moved to \(boundary)"
            }
        }
        return try await eventLog.prune(beforeSeq: boundary)
    }

    /// The `events_retention_days` job: prune everything recorded more than `days` ago.
    public static func applyRetention(days: Int, clock: any GatewayClock, eventLog: EventLog, grants: Grants) async throws -> (deleted: Int, oldestSeq: Int64) {
        let cutoff = clock.now.addingTimeInterval(-Double(days) * 86_400)
        let boundary = try await eventLog.seq(recordedAtOrAfter: cutoff)
        return try await pruneEvents(boundary: boundary, force: false, eventLog: eventLog, grants: grants)
    }

    /// Expire and purge access requests, delete old revoked grants, drop stale limiter windows.
    public static func sweep(accessRequests: AccessRequests, grants: Grants, rateLimiter: RateLimiter) async {
        try? await accessRequests.sweep()
        try? await grants.sweepRevoked()
        await rateLimiter.sweep()
    }
}
