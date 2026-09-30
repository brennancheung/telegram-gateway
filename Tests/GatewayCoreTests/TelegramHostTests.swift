import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

@Suite struct TelegramHostTests {
    let first = TelegramCredentials(apiId: 12345, apiHash: "aaaa")
    let second = TelegramCredentials(apiId: 12345, apiHash: "bbbb")

    @Test func withoutCredentialsTheHostIsDisabled() async throws {
        let ledger = FakeSessionLedger()
        let host = TelegramHost(factory: ledger.factory())
        #expect(try await host.apply(nil) == .disabled)
        #expect(await host.authState() == nil)
        #expect(await host.authStateName() == "unknown")
        #expect(await host.requesting() == nil)
        #expect(ledger.created.isEmpty)
        #expect(await apiError { try await host.request("getMe") }?.code == "not_logged_in")
        #expect(await apiError { try await host.requestQr() }?.status == 503)
    }

    @Test func startedUnchangedRestartedDisabled() async throws {
        let ledger = FakeSessionLedger()
        let tdlib = FakeTDLib()
        await Fixtures.populate(tdlib)
        let host = TelegramHost(factory: ledger.factory(tdlib: tdlib))

        // No credentials → credentials: a session is created and the login flow is available.
        #expect(try await host.apply(first) == .started)
        #expect(ledger.created == [first] && ledger.live == 1)
        #expect(await host.authState() == .waitPhoneNumber)
        try await host.requestQr()
        #expect(await host.qrLink() == "tg://login?token=FAKE")
        #expect(try await host.request("getChat", ["chat_id": Fixtures.channelId]).object.string("title") == "Acme Product Updates")

        // Same credentials → nothing is touched.
        #expect(try await host.apply(first) == .unchanged)
        #expect(ledger.created.count == 1)
        #expect(await ledger.sessions[0].calls == ["start", "qr"])

        // Changed credentials → the old session is shut down before the new one starts.
        #expect(try await host.apply(second) == .restarted)
        #expect(ledger.created == [first, second] && ledger.live == 1 && ledger.maxLive == 1)
        #expect(await ledger.sessions[0].calls == ["start", "qr", "shutdown"])
        #expect(await ledger.sessions[1].calls == ["start"])
        let credentialsNow = await host.currentCredentials
        #expect(await host.authState() == .waitPhoneNumber)
        #expect(credentialsNow == second)

        // Credentials removed → the session is closed and nothing replaces it.
        #expect(try await host.apply(nil) == .disabled)
        #expect(ledger.live == 0 && ledger.maxLive == 1)
        #expect(await host.authState() == nil)
        #expect(try await host.apply(nil) == .disabled)
    }

    @Test func updatesFlowThroughOneStreamAcrossSessions() async throws {
        let ledger = FakeSessionLedger()
        let host = TelegramHost(factory: ledger.factory())
        var iterator = host.updates.makeAsyncIterator()
        _ = try await host.apply(first)
        await ledger.sessions[0].push(Fixtures.updateConnectionState("connectionStateReady"))
        #expect(await iterator.next()?.object.type == "updateConnectionState")
        _ = try await host.apply(second)
        await ledger.sessions[1].push(Fixtures.updateChatTitle(chatId: 1, title: "x"))
        #expect(await iterator.next()?.object.type == "updateChatTitle")
        await host.shutdown()
        #expect(await iterator.next() == nil)
        #expect(ledger.live == 0)
    }

    @Test func aSessionThatWillNotCloseIsNeverReplaced() async throws {
        let ledger = FakeSessionLedger()
        let host = TelegramHost(factory: ledger.factory())
        _ = try await host.apply(first)
        await ledger.sessions[0].set(closesCleanly: false)
        let error = await apiError { try await host.apply(second) }
        #expect(error?.status == 500 && error?.code == "internal")
        #expect(ledger.created == [first] && ledger.maxLive == 1)
        #expect(await host.currentCredentials == first)
    }

    @Test func reloaderReportsWhatNeedsARestart() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "tgw-reload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try paths.prepare()
        let ledger = FakeSessionLedger()
        let host = TelegramHost(factory: ledger.factory())
        let reloader = ConfigReloader(paths: paths, running: Config(), host: host, environment: [:])
        #expect(try await reloader.reload() == ReloadResult(telegram: .disabled, restartRequired: []))
        try Data(#"{"api_id": 12345, "api_hash": "aaaa", "port": 5000, "events_retention_days": 30}"#.utf8).write(to: paths.config)
        let result = try await reloader.reload()
        #expect(result == ReloadResult(telegram: .started, restartRequired: ["port", "events_retention_days"]))
        #expect(result.json == ["reloaded": true, "telegram": "started", "restart_required": ["port", "events_retention_days"]])
        try Data("not json".utf8).write(to: paths.config)
        #expect(await apiError { try await reloader.reload() }?.details["field"] == "config.json")
        #expect(ledger.live == 1) // a broken file leaves the running session alone
    }
}
