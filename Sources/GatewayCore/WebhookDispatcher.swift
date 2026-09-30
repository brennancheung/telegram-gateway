import Foundation
import Logging

/// The outbound HTTP the dispatcher needs: one POST, one status code. `URLSessionWebhookClient`
/// is the real one; tests substitute a fake that records requests and scripts responses.
public protocol WebhookHTTPClient: Sendable {
    /// Returns the HTTP status. Throws on connection failure, TLS error or timeout. Redirects
    /// are not followed (their 3xx status is returned and counts as failure).
    func post(url: URL, headers: [(String, String)], body: Data, timeout: Duration) async throws -> Int
}

public struct URLSessionWebhookClient: WebhookHTTPClient {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func post(url: URL, headers: [(String, String)], body: Data, timeout: Duration) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Double(timeout.components.seconds)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GatewayError.unavailable("not an HTTP response") }
        return http.statusCode
    }
}

/// Delivers events to webhooks (docs/api.md "Webhooks"): one loop per grant, one delivery in
/// flight at a time, batches of ≤100 events / 4 MiB / 500 ms, HMAC-SHA256 signatures, the
/// documented retry ladder, pause after `24:00:00` of failure or a `410`, persisted cursors.
public actor WebhookDispatcher {
    public static let maxBatchEvents = 100
    public static let maxBatchBytes = 4 * 1024 * 1024
    public static let batchDelay: Duration = .milliseconds(500)
    public static let deliveryTimeout: Duration = .seconds(10)
    public static let pauseAfter: TimeInterval = 24 * 3600
    /// Delay before attempt N is `retryDelays[N - 2]`; past the table, one hour each.
    public static let retryDelays: [Duration] = [
        .seconds(10), .seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600), .seconds(1800), .seconds(3600),
    ]

    public static func retryDelay(beforeAttempt attempt: Int) -> Duration {
        let index = attempt - 2
        guard index >= 0 else { return .zero }
        return index < retryDelays.count ? retryDelays[index] : .seconds(3600)
    }

    private let store: Store
    private let eventLog: EventLog
    private let grants: Grants
    private let http: any WebhookHTTPClient
    private let clock: any GatewayClock
    private let logger: Logger

    private var loops: [String: Task<Void, Never>] = [:]
    private var wakers: [String: AsyncStream<Void>.Continuation] = [:]
    private var supervisor: Task<Void, Never>?

    public init(
        store: Store, eventLog: EventLog, grants: Grants, http: any WebhookHTTPClient,
        clock: any GatewayClock = SystemClock(), logger: Logger = Logger(label: "webhooks")
    ) {
        self.store = store
        self.eventLog = eventLog
        self.grants = grants
        self.http = http
        self.clock = clock
        self.logger = logger
    }

    // MARK: Lifecycle

    /// Starts a loop for every grant with a webhook and watches the log and revocations.
    public func start() async {
        guard supervisor == nil else { return }
        await syncLoops()
        let heads = await eventLog.subscribe()
        let revocations = await grants.revocations()
        supervisor = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in heads { await self?.wakeAll() }
                }
                group.addTask {
                    for await grantId in revocations { await self?.stop(grantId: grantId) }
                }
            }
        }
    }

    public func shutdown() {
        supervisor?.cancel()
        supervisor = nil
        for (_, task) in loops { task.cancel() }
        loops.removeAll()
        for (_, waker) in wakers { waker.finish() }
        wakers.removeAll()
    }

    /// Ensures a loop exists for each grant with a webhook (after approval, `PUT /v1/me/webhook`).
    public func syncLoops() async {
        guard let withWebhooks = try? await grants.grantsWithWebhooks() else { return }
        for grant in withWebhooks where loops[grant.id] == nil {
            startLoop(grantId: grant.id)
        }
    }

    /// Wakes one grant's loop (resume, new URL) — starting it if needed.
    public func wake(grantId: String) async {
        if loops[grantId] == nil { await syncLoops() }
        wakers[grantId]?.yield()
    }

    public func stop(grantId: String) {
        loops[grantId]?.cancel()
        loops.removeValue(forKey: grantId)
        wakers[grantId]?.finish()
        wakers.removeValue(forKey: grantId)
    }

    public var activeLoopCount: Int { loops.count }

    private func wakeAll() {
        for (_, waker) in wakers { waker.yield() }
    }

    private func startLoop(grantId: String) {
        let (wakeups, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakers[grantId] = continuation
        loops[grantId] = Task { [weak self] in
            var iterator = wakeups.makeAsyncIterator()
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.deliverPending(grantId: grantId)
                switch outcome {
                case .stop:
                    await self.loopEnded(grantId: grantId)
                    return
                case .wait:
                    guard await iterator.next() != nil else { return }
                case .again:
                    continue
                }
            }
        }
    }

    private func loopEnded(grantId: String) {
        loops.removeValue(forKey: grantId)
        wakers[grantId]?.finish()
        wakers.removeValue(forKey: grantId)
    }

    private enum Outcome {
        /// Nothing to deliver, or paused: sleep until woken.
        case wait
        /// A batch went through; check for more at once.
        case again
        /// Grant gone or webhook removed: end the loop.
        case stop
    }

    // MARK: Delivery

    /// One pass: pick up an unfinished delivery or build the next batch, deliver it through
    /// the retry ladder, persist the outcome.
    private func deliverPending(grantId: String) async -> Outcome {
        do {
            try Task.checkCancellation()
            guard let grant = try await store.grant(grantId), !grant.isRevoked, let webhook = grant.webhook else { return .stop }
            if webhook.state == .paused { return .wait }

            let types = Grants.visibleEventTypes(scopes: grant.scopes)
            let chats = Set(try await grants.effectiveChatIds(grant))

            var delivery: Delivery
            var events: [Event]
            if let unfinished = try await store.inFlightDelivery(grantId: grantId) {
                // The daemon stopped before the result was known: send again (at least once).
                delivery = unfinished
                events = try await store.events(seqs: unfinished.seqs)
            } else {
                var page = try await eventLog.page(since: webhook.cursorSeq, limit: WebhookDispatcher.maxBatchEvents, types: types, chatIds: chats)
                if page.events.isEmpty { return .wait }
                if page.events.count < WebhookDispatcher.maxBatchEvents {
                    // Give the burst 500 ms to accumulate, then take what is there.
                    try await clock.sleep(for: WebhookDispatcher.batchDelay)
                    page = try await eventLog.page(since: webhook.cursorSeq, limit: WebhookDispatcher.maxBatchEvents, types: types, chatIds: chats)
                }
                events = WebhookDispatcher.trimToSize(page.events)
                try Task.checkCancellation()
                delivery = Delivery(id: Identifiers.deliveryId(), grantId: grantId, seqs: events.map { $0.seq ?? 0 }, attempt: 1, status: .inFlight, sentAt: clock.now)
                try await store.insertDelivery(delivery)
            }

            return try await run(delivery: &delivery, events: events, grantId: grantId)
        } catch is CancellationError {
            return .stop
        } catch let error as EventLog.PageError {
            // The cursor fell below retained history: skip to the oldest and report a gap.
            if case .historyPruned(let oldest) = error {
                try? await grants.updateWebhook(grantId: grantId) { $0.cursorSeq = oldest - 1; $0.lastError = "history pruned; resumed at \(oldest)" }
            }
            return .again
        } catch {
            logger.error("webhook loop for \(grantId): \(error)")
            return .wait
        }
    }

    private func run(delivery: inout Delivery, events: [Event], grantId: String) async throws -> Outcome {
        while true {
            try Task.checkCancellation()
            guard let grant = try await store.grant(grantId), !grant.isRevoked, var webhook = grant.webhook else { return .stop }
            guard let url = URL(string: webhook.url) else {
                try await fail(&delivery, webhook: &webhook, grantId: grantId, status: nil, error: "invalid URL", pauseNow: true)
                return .wait
            }
            delivery.sentAt = clock.now
            try await store.updateDelivery(delivery)
            let body = WebhookDispatcher.body(deliveryId: delivery.id, grantId: grantId, sentAt: delivery.sentAt, events: events)
            let headers: [(String, String)] = [
                ("Content-Type", "application/json; charset=utf-8"),
                ("User-Agent", "TelegramGateway/1"),
                ("X-TGW-Delivery-Id", delivery.id),
                ("X-TGW-Seq", String(delivery.lastSeq)),
                ("X-TGW-Attempt", String(delivery.attempt)),
                ("X-TGW-Signature", WebhookSignature.header(secret: webhook.secret, body: body)),
            ]
            var status: Int?
            var failure: String?
            do {
                status = try await http.post(url: url, headers: headers, body: body, timeout: WebhookDispatcher.deliveryTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = String(describing: error)
            }

            if let status, (200..<300).contains(status) {
                delivery.status = .succeeded
                delivery.httpStatus = status
                delivery.completedAt = clock.now
                try await store.updateDelivery(delivery)
                let last = delivery.lastSeq
                let at = delivery.completedAt
                try await grants.updateWebhook(grantId: grantId) { w in
                    w.cursorSeq = max(w.cursorSeq, last)
                    w.state = .active
                    w.lastDeliveryAt = at
                    w.lastError = nil
                    w.failingSince = nil
                }
                return .again
            }

            let message = status.map { "HTTP \($0)" } ?? (failure ?? "failed")
            if status == 410 {
                try await fail(&delivery, webhook: &webhook, grantId: grantId, status: status, error: message, pauseNow: true)
                return .wait
            }
            let now = clock.now
            let failingSince = webhook.failingSince ?? now
            let nextAttempt = delivery.attempt + 1
            let delay = WebhookDispatcher.retryDelay(beforeAttempt: nextAttempt)
            let delaySeconds = Double(delay.components.seconds)
            if now.timeIntervalSince(failingSince) + delaySeconds > WebhookDispatcher.pauseAfter {
                try await fail(&delivery, webhook: &webhook, grantId: grantId, status: status, error: message, pauseNow: true)
                return .wait
            }
            delivery.httpStatus = status
            delivery.error = message
            try await store.updateDelivery(delivery)
            try await grants.updateWebhook(grantId: grantId) { w in
                w.state = .retrying
                w.lastError = message
                w.failingSince = failingSince
            }
            logger.warning("webhook \(grantId) delivery \(delivery.id) attempt \(delivery.attempt) failed (\(message)); retrying in \(delaySeconds)s")
            try await clock.sleep(for: delay)
            delivery.attempt = nextAttempt
        }
    }

    private func fail(_ delivery: inout Delivery, webhook: inout Webhook, grantId: String, status: Int?, error: String, pauseNow: Bool) async throws {
        delivery.status = .failed
        delivery.httpStatus = status
        delivery.error = error
        delivery.completedAt = clock.now
        try await store.updateDelivery(delivery)
        let now = clock.now
        try await grants.updateWebhook(grantId: grantId) { w in
            w.state = .paused
            w.pausedAt = now
            w.lastError = error
            w.failingSince = w.failingSince ?? now
        }
        logger.warning("webhook \(grantId) paused: \(error)")
    }

    // MARK: Batches

    /// Drops trailing events until the batch body fits in 4 MiB (always keeps at least one).
    public static func trimToSize(_ events: [Event]) -> [Event] {
        var events = events
        while events.count > 1 {
            let size = body(deliveryId: "dlv_0000000000000000", grantId: "grant_0000000000000000", sentAt: Date(), events: events).count
            if size <= maxBatchBytes { break }
            events.removeLast()
        }
        return events
    }

    /// The delivery body, byte-exact: this is what gets signed.
    public static func body(deliveryId: String, grantId: String, sentAt: Date, events: [Event]) -> Data {
        let json: JSONValue = [
            "v": .number(Double(Event.formatVersion)),
            "delivery_id": .string(deliveryId),
            "grant_id": .string(grantId),
            "sent_at": .date(sentAt),
            "events": .array(events.map { $0.json() }),
        ]
        return json.serialized()
    }
}
