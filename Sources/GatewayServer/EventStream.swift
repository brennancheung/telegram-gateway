import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOWebSocket
import WSCore

/// `GET /v1/events/stream` (docs/api.md "WebSocket"): backlog from `since`, `caught_up`,
/// then live events; heartbeats every 30s when idle; the documented close codes.
struct EventStream {
    static let heartbeatInterval: Duration = .seconds(30)
    static let maxConnectionsPerToken = 4
    static let slowConsumerLag: Int64 = 10_000
    static let backlogPageSize = 500

    let deps: Dependencies

    /// What the upgrade decided, carried into the handler through the request context.
    struct Session: Sendable {
        var principal: Principal
        var since: Int64?
        var filter: EventFilter
    }

    func register(on group: RouterGroup<GatewayRequestContext>) {
        group.ws("/events/stream", shouldUpgrade: { request, context in
            try await shouldUpgrade(request, context)
        }, onUpgrade: { inbound, outbound, context in
            try await run(inbound: inbound, outbound: outbound, context: context)
        })
    }

    /// Only the upgrade itself is checked here. Everything else (token, scopes, limits) is
    /// reported through close codes after the upgrade, because the WebSocket channel cannot
    /// deliver a JSON error response when it refuses an upgrade.
    func shouldUpgrade(_ request: Request, _ context: GatewayRequestContext) async throws -> RouterShouldUpgrade {
        guard request.headers[.upgrade]?.lowercased() == "websocket" else {
            throw APIError.invalidRequest("upgrade", "this endpoint is a WebSocket; connect with an Upgrade: websocket request")
        }
        return .upgrade([:])
    }

    func run(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, context: WebSocketRouterContext<GatewayRequestContext>) async throws {
        let principal: Principal
        do {
            principal = try await deps.grants.authenticate(bearer: AuthMiddleware.bearer(context.request))
        } catch let error as APIError {
            try await writeErrorAndClose(outbound, error, code: 4401)
            return
        }
        let budget = await deps.rateLimiter.hit("token:\(principal.rateLimitKey)", limit: AuthMiddleware.requestsPerMinute)
        guard budget.allowed else {
            try await writeErrorAndClose(outbound, APIError.rateLimited(retryAfter: budget.retryAfter), code: 4429)
            return
        }
        let query = Query(context.request)
        let filter: EventFilter
        do {
            filter = try await EventFilter(deps: deps, principal: principal, types: try query.eventTypes(), chatIds: try query.chatIds())
            _ = try query.int64("since")
        } catch let error as APIError {
            try await writeErrorAndClose(outbound, error, code: 4400)
            return
        }
        if let grant = principal.grant, !grant.has(.messagesRead), !grant.has(.chatsRead) {
            try await outbound.close(.unknown(4403), reason: "grant lacks messages:read and chats:read")
            return
        }
        let slotKey = "ws:\(principal.rateLimitKey)"
        guard await deps.rateLimiter.acquire(slotKey, max: EventStream.maxConnectionsPerToken) else {
            try await outbound.close(.unknown(4409), reason: "too many connections for this token")
            return
        }
        defer { Task { await deps.rateLimiter.release(slotKey) } }

        let writer = FrameWriter(outbound: outbound, clock: deps.clock)
        var cursor: Int64
        if let since = try query.int64("since") {
            // Backlog first, in pages, then caught_up at the head as of the last page.
            cursor = since
            while true {
                let page: EventLog.Page
                do {
                    page = try await deps.eventLog.page(since: cursor, limit: EventStream.backlogPageSize, types: filter.types, chatIds: filter.chatIds)
                } catch EventLog.PageError.historyPruned(let oldest) {
                    try await writer.send(EventStream.errorFrame(APIError.historyPruned(oldestSeq: oldest)))
                    try await outbound.close(.unknown(4410), reason: "history_pruned")
                    return
                }
                for event in page.events { try await writer.send(EventStream.eventFrame(event)) }
                cursor = max(page.nextSince, cursor)
                if !page.hasMore {
                    cursor = max(cursor, page.headSeq)
                    try await writer.send(["type": "caught_up", "seq": .number(Double(page.headSeq))])
                    break
                }
            }
        } else {
            cursor = try await deps.eventLog.headSeq()
            try await writer.send(["type": "caught_up", "seq": .number(Double(cursor))])
        }

        let heads = await deps.eventLog.subscribe()
        let revocations = await deps.grants.revocations()
        let shutdown = await deps.shutdown.subscribe()
        let grantId = principal.grant?.id
        let clock = deps.clock
        let eventLog = deps.eventLog
        let liveCursor = cursor

        enum Signal { case head, closedByClient, revoked, shutdown, heartbeat, slow }
        let outcome: Signal = await withTaskGroup(of: Signal.self) { group in
            // Live events: page from the cursor on every new head.
            group.addTask {
                var cursor = liveCursor
                for await _ in heads {
                    do {
                        while true {
                            let head = try await eventLog.headSeq()
                            if head - cursor > EventStream.slowConsumerLag { return .slow }
                            let page = try await eventLog.page(since: cursor, limit: EventStream.backlogPageSize, types: filter.types, chatIds: filter.chatIds)
                            for event in page.events { try await writer.send(EventStream.eventFrame(event)) }
                            cursor = max(cursor, page.hasMore ? page.nextSince : page.headSeq)
                            if !page.hasMore { break }
                        }
                    } catch {
                        return .closedByClient
                    }
                }
                return .closedByClient
            }
            // Heartbeat when nothing was sent for 30s.
            group.addTask {
                while true {
                    do { try await clock.sleep(for: EventStream.heartbeatInterval) } catch { return .closedByClient }
                    let idle = await writer.idleSince(clock.now)
                    guard idle >= Double(EventStream.heartbeatInterval.components.seconds) else { continue }
                    do {
                        let head = try await eventLog.headSeq()
                        try await writer.send(["type": "heartbeat", "seq": .number(Double(head)), "time": .date(clock.now)])
                    } catch {
                        return .closedByClient
                    }
                }
            }
            // The client's frames: nothing is expected; the stream ending means it went away.
            group.addTask {
                do { for try await _ in inbound {} } catch {}
                return .closedByClient
            }
            group.addTask {
                for await revoked in revocations where revoked == grantId { return .revoked }
                return .closedByClient
            }
            group.addTask {
                for await _ in shutdown { return .shutdown }
                return .closedByClient
            }
            let first = await group.next() ?? .closedByClient
            group.cancelAll()
            return first
        }

        switch outcome {
        case .revoked: try? await outbound.close(.unknown(4499), reason: "grant revoked")
        case .shutdown: try? await outbound.close(.goingAway, reason: "daemon shutting down")
        case .slow:
            try? await writer.send(EventStream.errorFrame(APIError(status: 0, code: "slow_consumer", message: "More than \(EventStream.slowConsumerLag) events behind; reconnect with since.")))
            try? await outbound.close(.policyViolation, reason: "slow_consumer")
        case .closedByClient, .head, .heartbeat: break
        }
    }

    private func writeErrorAndClose(_ outbound: WebSocketOutboundWriter, _ error: APIError, code: UInt16) async throws {
        try? await outbound.write(.text(EventStream.errorFrame(error).serializedString()))
        try await outbound.close(.unknown(code), reason: error.code)
    }

    static func eventFrame(_ event: Event) -> JSONValue {
        ["type": "event", "event": event.json()]
    }

    static func errorFrame(_ error: APIError) -> JSONValue {
        ["type": "error", "code": .string(error.code), "message": .string(error.message), "details": .object(error.details)]
    }
}

/// Serialises writes from the live, heartbeat and backlog paths and remembers when the last
/// frame went out.
actor FrameWriter {
    private let outbound: WebSocketOutboundWriter
    private let clock: any GatewayClock
    private var lastSentAt: Date

    init(outbound: WebSocketOutboundWriter, clock: any GatewayClock) {
        self.outbound = outbound
        self.clock = clock
        lastSentAt = clock.now
    }

    func send(_ frame: JSONValue) async throws {
        try await outbound.write(.text(frame.serializedString()))
        lastSentAt = clock.now
    }

    func idleSince(_ now: Date) -> TimeInterval {
        now.timeIntervalSince(lastSentAt)
    }
}
