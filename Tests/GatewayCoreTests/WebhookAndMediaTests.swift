import CryptoKit
import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

@Suite struct WebhookDispatcherTests {
    struct Harness {
        let core: Core
        let http: FakeWebhookClient
        let dispatcher: WebhookDispatcher
        let grant: Grant
        let secret: String

        init(scopes: [Scope] = [.messagesRead, .chatsRead]) async throws {
            core = try await Core()
            // Seed the monitored set without going through the monitor so no events precede the grant.
            try await core.store.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.channelId, Fixtures.groupId]), now: core.clock.now)
            http = FakeWebhookClient()
            let issued = try await core.grants.create(name: "A", description: "D", scopes: scopes, chats: .list([Fixtures.channelId]), webhookUrl: "https://analytics.example.com/tgw/events")
            grant = issued.grant
            secret = try #require(issued.webhookSecret)
            dispatcher = WebhookDispatcher(store: core.store, eventLog: core.eventLog, grants: core.grants, http: http, clock: core.clock)
            await dispatcher.start()
        }

        func webhook() async throws -> Webhook {
            try #require(try await core.store.grant(grant.id)?.webhook)
        }

        /// Appends one event and lets the batching delay pass.
        func appendAndFlush(id: Int64) async throws {
            _ = try await core.appendMessageEvent(id: id)
            try await core.clock.waitForSleepers(1)
            core.clock.advance(by: .milliseconds(500))
        }
    }

    @Test func singleEventWaitsTheBatchDelayThenDeliversSigned() async throws {
        let h = try await Harness()
        _ = try await h.core.appendMessageEvent(id: 1, text: "hello")
        try await h.core.clock.waitForSleepers(1)
        #expect(await h.http.requests.isEmpty)
        h.core.clock.advance(by: .milliseconds(500))
        try await h.http.waitForRequests(1)
        let request = try #require(await h.http.requests.first)
        #expect(request.url.absoluteString == "https://analytics.example.com/tgw/events")
        #expect(request.header("Content-Type") == "application/json; charset=utf-8")
        #expect(request.header("User-Agent") == "TelegramGateway/1")
        #expect(request.header("X-TGW-Seq") == "1" && request.header("X-TGW-Attempt") == "1")
        #expect(request.header("X-TGW-Delivery-Id")?.hasPrefix("dlv_") == true)
        #expect(request.timeout == .seconds(10))
        let expected = "sha256=" + HMAC<SHA256>.authenticationCode(for: request.body, using: SymmetricKey(data: Data(h.secret.utf8))).map { String(format: "%02x", $0) }.joined()
        #expect(request.header("X-TGW-Signature") == expected)
        let body = try JSONValue.parse(request.body)
        #expect(body["v"] == 1 && body["grant_id"] == .string(h.grant.id) && body["delivery_id"] == .string(request.header("X-TGW-Delivery-Id") ?? ""))
        #expect(body["events"]?.arrayValue?.count == 1 && body["events"]?[0]?["seq"] == 1 && body["events"]?[0]?["message"]?["text"] == "hello")
        try await Task.sleep(for: .milliseconds(50))
        let webhook = try await h.webhook()
        #expect(webhook.cursorSeq == 1 && webhook.state == .active && webhook.lastDeliveryAt == h.core.clock.now)
        let deliveries = try await h.core.store.deliveries(grantId: h.grant.id, limit: 10)
        #expect(deliveries.count == 1 && deliveries[0].status == .succeeded && deliveries[0].httpStatus == 200 && deliveries[0].seqs == [1])
    }

    @Test func hundredPendingEventsGoImmediatelyInOneBatchAndTheRestFollow() async throws {
        let h = try await Harness()
        await h.dispatcher.stop(grantId: h.grant.id)
        for i in 1...130 { _ = try await h.core.appendMessageEvent(id: Int64(i)) }
        await h.dispatcher.wake(grantId: h.grant.id)
        try await h.http.waitForRequests(1)
        let first = try JSONValue.parse(await h.http.requests[0].body)
        #expect(first["events"]?.arrayValue?.count == 100)
        #expect(await h.http.requests[0].header("X-TGW-Seq") == "100")
        // 30 remain: fewer than 100, so the 500 ms delay applies once more.
        try await h.core.clock.waitForSleepers(1)
        h.core.clock.advance(by: .milliseconds(500))
        try await h.http.waitForRequests(2)
        let second = try JSONValue.parse(await h.http.requests[1].body)
        let seqs = second["events"]?.arrayValue?.compactMap { $0["seq"]?.intValue } ?? []
        #expect(seqs.count == 30 && seqs.first == 101, "got \(seqs.count) events: \(seqs.prefix(3))…\(seqs.suffix(3))")
    }

    @Test func onlyEventsTheGrantCanSeeAreDelivered() async throws {
        let h = try await Harness(scopes: [.messagesRead])
        _ = try await h.core.appendChatEvent(chatId: Fixtures.channelId) // needs chats:read
        _ = try await h.core.appendMessageEvent(chatId: Fixtures.groupId, id: 1) // not granted
        _ = try await h.core.appendMessageEvent(chatId: Fixtures.channelId, id: 2)
        try await h.core.clock.waitForSleepers(1)
        h.core.clock.advance(by: .milliseconds(500))
        try await h.http.waitForRequests(1)
        let body = try JSONValue.parse(await h.http.requests[0].body)
        #expect(body["events"]?.arrayValue?.map { $0["seq"] } == [3])
    }

    @Test func retryLadderThenSuccess() async throws {
        let h = try await Harness()
        await h.http.enqueue(.status(500))
        await h.http.enqueue(.failure("connection refused"))
        await h.http.enqueue(.status(302))
        try await h.appendAndFlush(id: 1)
        try await h.http.waitForRequests(1)
        try await Task.sleep(for: .milliseconds(30))
        var webhook = try await h.webhook()
        #expect(webhook.state == .retrying && webhook.lastError == "HTTP 500" && webhook.failingSince == h.core.clock.now)
        // Attempt 2 after 10s.
        try await h.core.clock.waitForSleepers(1)
        h.core.clock.advance(by: .seconds(9))
        #expect(await h.http.requests.count == 1)
        h.core.clock.advance(by: .seconds(1))
        try await h.http.waitForRequests(2)
        #expect(await h.http.requests[1].header("X-TGW-Attempt") == "2")
        #expect(await h.http.requests[1].header("X-TGW-Delivery-Id") == h.http.requests[0].header("X-TGW-Delivery-Id"))
        // Attempt 3 after 30s more.
        try await h.core.clock.waitForSleepers(1)
        h.core.clock.advance(by: .seconds(30))
        try await h.http.waitForRequests(3)
        // Attempt 4 after 01:00 more succeeds.
        try await h.core.clock.waitForSleepers(1)
        h.core.clock.advance(by: .seconds(60))
        try await h.http.waitForRequests(4)
        try await Task.sleep(for: .milliseconds(50))
        webhook = try await h.webhook()
        #expect(webhook.state == .active && webhook.cursorSeq == 1 && webhook.failingSince == nil && webhook.lastError == nil)
        let delivery = try #require(try await h.core.store.deliveries(grantId: h.grant.id, limit: 1).first)
        #expect(delivery.attempt == 4 && delivery.status == .succeeded)
        #expect(WebhookDispatcher.retryDelay(beforeAttempt: 9) == .seconds(3600) && WebhookDispatcher.retryDelay(beforeAttempt: 31) == .seconds(3600))
    }

    @Test func gonePausesImmediatelyAndResumeContinuesFromCursor() async throws {
        let h = try await Harness()
        await h.http.enqueue(.status(410))
        try await h.appendAndFlush(id: 1)
        try await h.http.waitForRequests(1)
        try await Task.sleep(for: .milliseconds(50))
        var webhook = try await h.webhook()
        #expect(webhook.state == .paused && webhook.pausedAt == h.core.clock.now && webhook.cursorSeq == 0)
        // Events accumulate while paused; nothing is sent.
        _ = try await h.core.appendMessageEvent(id: 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.http.requests.count == 1)
        _ = try await h.core.grants.resumeWebhook(grantId: h.grant.id)
        await h.dispatcher.wake(grantId: h.grant.id)
        try await h.core.clock.waitForSleepers(1)
        h.core.clock.advance(by: .milliseconds(500))
        try await h.http.waitForRequests(2)
        let body = try JSONValue.parse(await h.http.requests[1].body)
        #expect(body["events"]?.arrayValue?.map { $0["seq"] } == [1, 2])
        try await Task.sleep(for: .milliseconds(50))
        webhook = try await h.webhook()
        #expect(webhook.state == .active && webhook.cursorSeq == 2)
    }

    @Test func pausesAfterTwentyFourHoursOfFailure() async throws {
        let h = try await Harness()
        await h.http.setDefault(.status(503))
        try await h.appendAndFlush(id: 1)
        var attempts = 1
        try await h.http.waitForRequests(attempts)
        // Walk the ladder: 8 tabled delays then hourly. Attempt 31 lands at 23:48:40; the
        // 32nd would pass 24:00:00, so the webhook pauses instead.
        while attempts < 31 {
            try await h.core.clock.waitForSleepers(1)
            h.core.clock.advance(by: WebhookDispatcher.retryDelay(beforeAttempt: attempts + 1))
            attempts += 1
            try await h.http.waitForRequests(attempts)
        }
        try await Task.sleep(for: .milliseconds(100))
        let webhook = try await h.webhook()
        #expect(webhook.state == .paused && webhook.cursorSeq == 0)
        #expect(await h.http.requests.count == 31)
        let delivery = try #require(try await h.core.store.deliveries(grantId: h.grant.id, limit: 1).first)
        #expect(delivery.status == .failed && delivery.attempt == 31 && delivery.error == "HTTP 503")
        #expect(h.core.clock.sleeperCount == 0)
    }

    @Test func revocationStopsTheLoopAndDropsDeliveries() async throws {
        let h = try await Harness()
        #expect(await h.dispatcher.activeLoopCount == 1)
        try await h.core.grants.revoke(h.grant.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.dispatcher.activeLoopCount == 0)
        _ = try await h.core.appendMessageEvent(id: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.http.requests.isEmpty)
    }

    @Test func inFlightDeliveryIsResentAfterRestart() async throws {
        let h = try await Harness()
        await h.dispatcher.shutdown()
        _ = try await h.core.appendMessageEvent(id: 1)
        _ = try await h.core.appendMessageEvent(id: 2)
        // As if the daemon died after sending but before recording the result.
        try await h.core.store.insertDelivery(Delivery(id: "dlv_restart", grantId: h.grant.id, seqs: [1, 2], attempt: 1, status: .inFlight, sentAt: h.core.clock.now))
        let dispatcher = WebhookDispatcher(store: h.core.store, eventLog: h.core.eventLog, grants: h.core.grants, http: h.http, clock: h.core.clock)
        await dispatcher.start()
        await dispatcher.wake(grantId: h.grant.id)
        try await h.http.waitForRequests(1)
        #expect(await h.http.requests[0].header("X-TGW-Delivery-Id") == "dlv_restart")
        let body = try JSONValue.parse(await h.http.requests[0].body)
        #expect(body["events"]?.arrayValue?.map { $0["seq"] } == [1, 2])
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await h.webhook().cursorSeq == 2)
        await dispatcher.shutdown()
    }

    @Test func batchesNeverExceedFourMiB() async throws {
        let core = try await Core()
        var events: [Event] = []
        for i in 1...10 {
            let seq = try await core.appendMessageEvent(id: Int64(i), text: String(repeating: "x", count: 600_000))
            events += try await core.store.events(seqs: [seq])
        }
        let trimmed = WebhookDispatcher.trimToSize(events)
        #expect(trimmed.count < 10 && trimmed.count >= 6)
        #expect(WebhookDispatcher.body(deliveryId: "d", grantId: "g", sentAt: Date(), events: trimmed).count <= WebhookDispatcher.maxBatchBytes)
    }
}

@Suite struct MediaCacheTests {
    func setUp(maxBytes: Int64 = 1_000_000) async throws -> (Core, MediaCache, URL) {
        let core = try await Core()
        let dir = FileManager.default.temporaryDirectory.appending(path: "tgw-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = MediaCache(store: core.store, tdlib: core.tdlib, maxBytes: maxBytes, clock: core.clock)
        return (core, cache, dir)
    }

    func register(_ core: Core, id: Int, name: String, bytes: Int, dir: URL, completes: Bool = true) async throws -> String {
        let path = dir.appending(path: name).path
        try Data(repeating: 7, count: bytes).write(to: URL(filePath: path))
        let uniqueId = "u-\(name)"
        let mediaId = Identifiers.mediaId(uniqueId: uniqueId)
        let media = Media(mediaId: mediaId, kind: .document, mime: "application/octet-stream", size: Int64(bytes), width: nil, height: nil, durationSeconds: nil, fileName: name)
        try await core.store.recordMedia(MediaRecord(media: media, remoteId: "r-\(name)", uniqueId: uniqueId), chatId: Fixtures.channelId)
        await core.tdlib.add(file: JSONBox(Fixtures.file(id: id, remoteId: "r-\(name)", uniqueId: uniqueId, size: Int64(bytes))), completedPath: completes ? path : nil)
        return mediaId
    }

    @Test func downloadsOnFirstRequestThenServesFromDisk() async throws {
        let (core, cache, dir) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await register(core, id: 1, name: "a.bin", bytes: 100, dir: dir)
        #expect(try await cache.isCached(id) == false)
        let first = try await cache.fetch(id)
        #expect(first == .ready(path: dir.appending(path: "a.bin").path, bytes: 100))
        #expect(await core.tdlib.requests(ofType: "downloadFile").count == 1)
        #expect(try await cache.isCached(id))
        let second = try await cache.fetch(id)
        #expect(second == first)
        #expect(await core.tdlib.requests(ofType: "downloadFile").count == 1)
        #expect(try await cache.cachedBytes() == 100)
        #expect(await apiError { try await cache.fetch("med_unknown") }?.code == "not_found")
    }

    @Test func slowDownloadReportsProgress() async throws {
        let (core, cache, dir) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await register(core, id: 2, name: "slow.bin", bytes: 10, dir: dir, completes: false)
        let task = Task { try await cache.fetch(id, wait: .seconds(30)) }
        try await core.clock.waitForSleepers(1)
        core.clock.advance(by: .seconds(30))
        #expect(try await task.value == .downloading(bytesDownloaded: 0, size: 10))
    }

    @Test func evictsLeastRecentlyServedPastTheLimit() async throws {
        let (core, cache, dir) = try await setUp(maxBytes: 250)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await register(core, id: 3, name: "a.bin", bytes: 100, dir: dir)
        let b = try await register(core, id: 4, name: "b.bin", bytes: 100, dir: dir)
        let c = try await register(core, id: 5, name: "c.bin", bytes: 100, dir: dir)
        _ = try await cache.fetch(a)
        core.clock.advance(by: .seconds(1))
        _ = try await cache.fetch(b)
        core.clock.advance(by: .seconds(1))
        _ = try await cache.fetch(a) // a is now more recent than b
        core.clock.advance(by: .seconds(1))
        _ = try await cache.fetch(c) // 300 > 250 → evict b
        let aCached = try await cache.isCached(a)
        let bCached = try await cache.isCached(b)
        let cCached = try await cache.isCached(c)
        #expect(aCached && cCached && !bCached)
        #expect(try await cache.cachedBytes() == 200)
        #expect(await core.tdlib.requests(ofType: "deleteFile").count == 1)
    }

    @Test func goneWhenTelegramCannotServeIt() async throws {
        let (core, cache, dir) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = Media(mediaId: "med_gone", kind: .photo, mime: nil, size: nil, width: nil, height: nil, durationSeconds: nil, fileName: nil)
        try await core.store.recordMedia(MediaRecord(media: media, remoteId: "r-missing", uniqueId: "u-missing"), chatId: Fixtures.channelId)
        #expect(await apiError { try await cache.fetch("med_gone") }?.code == "media_gone")
    }
}

@Suite struct RateLimiterTests {
    @Test func fixedWindow() async {
        let clock = ManualClock()
        let limiter = RateLimiter(clock: clock)
        for i in 0..<3 {
            let d = await limiter.hit("k", limit: 3, window: 60)
            #expect(d.allowed && d.remaining == 2 - i && d.limit == 3)
        }
        let blocked = await limiter.hit("k", limit: 3, window: 60)
        #expect(!blocked.allowed && blocked.remaining == 0 && blocked.retryAfter == 60)
        clock.advance(by: .seconds(60))
        #expect(await limiter.hit("k", limit: 3, window: 60).allowed)
    }

    @Test func throttleAndSlots() async {
        let clock = ManualClock()
        let limiter = RateLimiter(clock: clock)
        #expect(await limiter.throttle("r", interval: 2).allowed)
        let again = await limiter.throttle("r", interval: 2)
        #expect(!again.allowed && again.retryAfter == 2)
        clock.advance(by: .seconds(2))
        #expect(await limiter.throttle("r", interval: 2).allowed)
        let first = await limiter.acquire("s", max: 2)
        let second = await limiter.acquire("s", max: 2)
        let third = await limiter.acquire("s", max: 2)
        #expect(first && second && !third)
        await limiter.release("s")
        #expect(await limiter.acquire("s", max: 2))
    }
}

@Suite struct FoundationTests {
    @Test func identifiers() {
        #expect(Identifiers.token().count == 47 && Identifiers.webhookSecret().count == 49 && Identifiers.grantId().count == 22 && Identifiers.deliveryId().count == 20)
        #expect(Identifiers.hash("x") == "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
        #expect(MessageId.toPublic(1523 << 20) == 1523 && MessageId.toInternal(1523) == 1596981248)
        #expect(WebhookSignature.header(secret: "s", body: Data("b".utf8)).hasPrefix("sha256=") && WebhookSignature.header(secret: "s", body: Data("b".utf8)).count == 71)
    }

    @Test func jsonValueSerialisesNullsInOrder() throws {
        let value: JSONValue = ["b": .null, "a": ["x": 1.5, "y": "q\"\n"], "n": 3, "i": .id(-1001234567890)]
        #expect(value.serializedString() == #"{"b":null,"a":{"x":1.5,"y":"q\"\n"},"n":3,"i":"-1001234567890"}"#)
        #expect(try JSONValue.parse(value.serialized())["a"]?["x"] == 1.5)
        #expect(try JSONValue.parse("[true, null, 2]") == [true, .null, 2])
    }

    @Test func timestamps() {
        #expect(Timestamp.format(Date(timeIntervalSince1970: 1_790_000_000)) == "2026-09-21T14:13:20Z")
        #expect(Timestamp.format(Date(timeIntervalSince1970: 1_790_000_000.412)) == "2026-09-21T14:13:20.412Z")
        #expect(Timestamp.parse("2026-09-21T14:13:20Z") == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(Timestamp.parse("2026-09-21T14:13:20.412Z") != nil)
    }

    @Test func configLoadsFileAndEnvironment() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "tgw-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try paths.prepare()
        #expect(try Config.load(paths: paths, environment: [:]) == Config())
        try Data(#"{"port": 5000, "events_retention_days": 30, "media_cache_max_bytes": 10, "api_id": 12345, "api_hash": "abc"}"#.utf8).write(to: paths.config)
        let loaded = try Config.load(paths: paths, environment: [:])
        #expect(loaded == Config(port: 5000, eventsRetentionDays: 30, mediaCacheMaxBytes: 10, apiId: 12345, apiHash: "abc") && loaded.hasCredentials)
        #expect(try Config.load(paths: paths, environment: ["TGW_PORT": "6000"]).port == 6000)
        #expect(Paths.resolve(environment: ["TGW_HOME": "/tmp/x"]).home.path == "/tmp/x")
        #expect(paths.database.lastPathComponent == "gateway.sqlite" && paths.lock.lastPathComponent == "daemon.lock")
    }

    @Test func instanceLockRefusesASecondHolder() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "tgw-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        #expect(InstanceLock.holder(paths: paths) == nil)
        let lock = try InstanceLock.acquire(paths: paths, role: "daemon")
        #expect(InstanceLock.holder(paths: paths)?.role == "daemon")
        #expect(throws: GatewayError.self) { try InstanceLock.acquire(paths: paths, role: "tgw login") }
        withExtendedLifetime(lock) {}
    }
}
