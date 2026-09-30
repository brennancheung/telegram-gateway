import Foundation

/// The append-only event log (docs/api.md "Events"). Wraps the store's `events` table with the
/// contract's semantics — exclusive `since`, `410 history_pruned` below the oldest retained
/// `seq` — and a per-process broadcast so WebSocket streams and the webhook dispatcher learn
/// about new events without polling.
public actor EventLog {
    /// One page of the log.
    public struct Page: Sendable, Equatable {
        public var events: [Event]
        public var hasMore: Bool
        /// The `seq` of the last event returned, or `since` when empty.
        public var nextSince: Int64
        /// The newest `seq` in the whole log.
        public var headSeq: Int64
    }

    public enum PageError: Error, Equatable {
        /// `since` is below the oldest retained event.
        case historyPruned(oldestSeq: Int64)
    }

    private let store: Store
    private let clock: any GatewayClock
    private var subscribers: [UUID: AsyncStream<Int64>.Continuation] = [:]
    private var cachedHead: Int64?

    public init(store: Store, clock: any GatewayClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// Appends the event (stamping `recorded_at` with the clock) and returns its `seq`. Every
    /// subscriber is notified with the new head.
    @discardableResult
    public func append(_ event: Event) async throws -> Int64 {
        var event = event
        event.recordedAt = clock.now
        let seq = try await store.appendEvent(event)
        cachedHead = seq
        for (_, continuation) in subscribers { continuation.yield(seq) }
        return seq
    }

    public func headSeq() async throws -> Int64 {
        if let cachedHead { return cachedHead }
        let head = try await store.headSeq()
        cachedHead = head
        return head
    }

    public func oldestSeq() async throws -> Int64? {
        try await store.oldestSeq()
    }

    /// A page after `since` (exclusive). `chatIds == nil` means every chat; `types == nil` every
    /// type. `limit` is clamped to 1…1000. Throws `PageError.historyPruned` when the consumer
    /// would miss pruned events: `since + 1` is below the oldest retained `seq`. `since = 0`
    /// is the documented "from the beginning of retained history" and never throws.
    public func page(since: Int64, limit: Int, types: Set<EventType>? = nil, chatIds: Set<Int64>? = nil) async throws -> Page {
        let limit = min(max(limit, 1), 1000)
        if since > 0, let oldest = try await store.oldestSeq(), since + 1 < oldest {
            throw PageError.historyPruned(oldestSeq: oldest)
        }
        var events = try await store.events(since: since, limit: limit + 1, types: types, chatIds: chatIds)
        let hasMore = events.count > limit
        if hasMore { events.removeLast() }
        let head = try await headSeq()
        return Page(events: events, hasMore: hasMore, nextSince: events.last?.seq ?? since, headSeq: head)
    }

    /// How many events after `since` a given filter would see (webhook `pending_events`).
    public func pendingCount(since: Int64, types: Set<EventType>?, chatIds: Set<Int64>?) async throws -> Int64 {
        try await store.eventCount(since: since, types: types, chatIds: chatIds)
    }

    /// Deletes events with `seq < beforeSeq`. Returns the count and the new oldest `seq` (the
    /// boundary when the log is now empty).
    public func prune(beforeSeq: Int64) async throws -> (deleted: Int, oldestSeq: Int64) {
        let deleted = try await store.pruneEvents(beforeSeq: beforeSeq)
        let oldest = try await store.oldestSeq() ?? beforeSeq
        return (deleted, oldest)
    }

    /// The `seq` boundary equivalent to `older_than: date`.
    public func seq(recordedAtOrAfter date: Date) async throws -> Int64 {
        try await store.firstSeq(recordedAtOrAfter: date)
    }

    /// New head sequence numbers as events are appended. Buffered so a slow subscriber never
    /// misses a wake-up; the value is only a hint to page again.
    public func subscribe() -> AsyncStream<Int64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    public var subscriberCount: Int { subscribers.count }
}
