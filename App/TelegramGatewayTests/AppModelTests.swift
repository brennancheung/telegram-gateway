import Foundation
import Testing
@testable import TelegramGateway

/// The model's screen decisions and the flows the screens drive, all against the fake.
@Suite("AppModel over FakeAPIClient")
@MainActor
struct AppModelTests {
    @Test("Screen follows the facts: setup → token → login → main")
    func screens() async {
        let noCredentials = AppModel.preview(.loggedIn, credentials: false)
        await noCredentials.refresh()
        #expect(noCredentials.screen == .setup)

        let down = AppModel.preview(.unreachable)
        await down.refresh()
        #expect(down.screen == .setup)
        #expect(!down.reachable)

        let noToken = AppModel.preview(.loggedIn, token: false)
        await noToken.refresh()
        #expect(noToken.screen == .tokenMissing)

        let loggedOut = AppModel.preview(.loggedOut)
        await loggedOut.refresh()
        #expect(loggedOut.screen == .login)

        let ready = AppModel.preview(.loggedIn)
        #expect(ready.screen == .loading)
        await ready.refresh()
        #expect(ready.screen == .main)
        #expect(ready.status?.account?.username == "brennan")
        #expect(ready.pendingRequestCount == 1)
    }

    @Test("QR login: link, rotation, scan, 2FA password")
    func qrLogin() async throws {
        let model = AppModel.preview(.loggedOut, has2FA: true)
        await model.refresh()
        await model.requestQR()
        #expect(model.authState == .waitQRConfirmation)
        let first = try #require(model.auth?.qrLink)
        #expect(LoginLink.isValid(first))
        await model.requestQR()
        let second = try #require(model.auth?.qrLink)
        #expect(LoginLink.changed(from: first, to: second))

        let fake = try #require(model.client as? FakeAPIClient)
        await fake.simulateQRScanned()
        await model.refreshAuth()
        #expect(model.authState == .waitPassword)
        #expect(model.auth?.passwordHint == "pet")

        await model.submitPassword("wrong")
        #expect(model.loginError != nil)
        #expect(model.authState == .waitPassword)
        await model.submitPassword("hunter2")
        #expect(model.loginError == nil)
        #expect(model.screen == .main)
    }

    @Test("Phone login: phone → code → ready")
    func phoneLogin() async {
        let model = AppModel.preview(.loggedOut, has2FA: false)
        await model.refresh()
        await model.submitPhone("12345")
        #expect(model.loginError != nil)
        await model.submitPhone("+15551234567")
        #expect(model.authState == .waitCode)
        #expect(model.auth?.phoneHint == "+15551234567")
        await model.submitCode("00000")
        #expect(model.loginError != nil)
        await model.submitCode("12345")
        #expect(model.screen == .main)
        await model.logout()
        #expect(model.screen == .login)
    }

    @Test("Monitored set: save replaces, effective count follows folders")
    func monitored() async {
        let model = AppModel.preview(.loggedInEmpty)
        await model.refresh()
        await model.loadChats()
        #expect(model.chats.count == Fixtures.chats.count)
        #expect(model.monitoredCount == 0)
        let saved = await model.saveMonitored(chatIds: ["-1001111111111"], folderIds: ["3"])
        #expect(saved)
        #expect(Set(model.monitored?.effectiveChatIds ?? []) == ["-1001111111111", "-1001234567890", "-1001987654321"])
        #expect(model.chats.first { $0.id == "-1001987654321" }?.isMonitored == true)
        #expect(model.folders.first { $0.id == "3" }?.isMonitored == true)
        let bad = await model.saveMonitored(chatIds: ["nope"], folderIds: [])
        #expect(!bad)
        #expect(model.chatsError != nil)
    }

    @Test("Approve monitors requested chats first, narrows scopes, creates the grant")
    func approve() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        let request = model.requests[0]
        #expect(model.grants.count == 2)
        let ok = await model.approve(request, selection: .chats(["-1001234567890", "-1001111111111"]), scopes: ["messages:read"], alsoMonitor: ["-1001111111111"])
        #expect(ok)
        #expect(model.requests.isEmpty)
        #expect(model.grants.count == 3)
        let grant = model.grants.last
        #expect(grant?.scopes == ["messages:read"])
        #expect(Set(grant?.effectiveChatIds ?? []) == ["-1001234567890", "-1001111111111"])
        #expect(grant?.webhook?.url == "https://analytics.example.com/tgw/events")
        #expect(model.monitored?.chatIds.contains("-1001111111111") == true)
    }

    @Test("Approve refuses an unmonitored chat and a scope that was not requested")
    func approveRejections() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadAccess()
        let request = model.requests[0]
        let unmonitored = await model.approve(request, selection: .chats(["-1001111111111"]), scopes: request.scopes, alsoMonitor: [])
        #expect(!unmonitored)
        #expect(model.accessError?.contains("not monitored") == true)
        let widened = await model.approve(request, selection: .chats(["-1001234567890"]), scopes: ["media:read"], alsoMonitor: [])
        #expect(!widened)
        #expect(model.requests.count == 1)
    }

    @Test("Deny, revoke, resume webhook")
    func denyRevokeResume() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadAccess()
        await model.deny(model.requests[0])
        #expect(model.requests.isEmpty)
        #expect(model.pendingRequestCount == 0)
        let paused = model.grants.first { $0.webhook?.state == .paused }!
        await model.resumeWebhook(paused)
        #expect(model.grants.first { $0.id == paused.id }?.webhook?.state == .active)
        await model.revoke(paused)
        #expect(model.grants.count == 1)
    }

    @Test("Config merge keeps unknown keys and the daemon locator reads config first")
    func configMerge() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tgw-config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        try Data(#"{"port": 41415, "events_retention_days": null, "custom": {"a": 1}}"#.utf8).write(to: file)
        setenv("TGW_HOME", directory.path, 1)
        defer { unsetenv("TGW_HOME") }
        let merged = try GatewayConfig.merge(["api_id": 12345, "api_hash": "0123456789abcdef0123456789abcdef", "daemon_path": "/tmp/GatewayDaemon"])
        #expect(merged.hasCredentials)
        #expect(merged.port == 41415)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(raw["events_retention_days"] is NSNull)
        #expect((raw["custom"] as? [String: Any])?["a"] as? Int == 1)
        #expect(raw["port"] as? Int == 41415)
        let reloaded = try GatewayConfig.load()
        #expect(reloaded == merged)
        let resolution = DaemonLocator.resolve(config: reloaded, environment: [:])
        #expect(resolution.candidates.first?.source == "config.json daemon_path")
        #expect(resolution.candidates.first?.url.path == "/tmp/GatewayDaemon")
        #expect(resolution.candidates.contains { $0.source == "app bundle" })
    }

    @Test("Admin token comes from secrets.json; Keychain only when config opts in")
    func adminTokenFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tgw-secrets-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "secrets.json")
        #expect(try AdminToken.readFile(at: file) == nil)
        try Data(#"{"admin-token": " tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV\n", "other": 1}"#.utf8).write(to: file)
        #expect(try AdminToken.readFile(at: file) == "tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV")
        try Data(#"{"other": 1}"#.utf8).write(to: file)
        #expect(try AdminToken.readFile(at: file) == nil)
        try Data("[]".utf8).write(to: file)
        #expect(throws: AdminToken.ReadError.self) { try AdminToken.readFile(at: file) }
        #expect(GatewayConfig().secretsSource == .file)
        #expect(GatewayConfig(raw: ["secrets": "keychain"]).secretsSource == .keychain)
        #expect(GatewayConfig(raw: ["secrets": "vault"]).secretsSource == .file)
        // The model's file path: TGW_HOME points the read at the scratch directory (no SecItem).
        setenv("TGW_HOME", directory.path, 1)
        defer { unsetenv("TGW_HOME") }
        try Data(#"{"admin-token": "tgw_fromfile"}"#.utf8).write(to: file)
        #expect(try AdminToken.read(config: GatewayConfig()) == "tgw_fromfile")
    }

    @Test("Credential validation")
    func credentials() {
        #expect(!GatewayConfig(apiId: nil, apiHash: nil).hasCredentials)
        #expect(!GatewayConfig(apiId: 0, apiHash: "0123456789abcdef0123456789abcdef").hasCredentials)
        #expect(!GatewayConfig(apiId: 1, apiHash: "short").hasCredentials)
        #expect(!GatewayConfig(apiId: 1, apiHash: "0123456789abcdef0123456789abcdeg").hasCredentials)
        #expect(GatewayConfig(apiId: 1, apiHash: "0123456789ABCDEF0123456789abcdef").hasCredentials)
        #expect(GatewayConfig(raw: ["api_id": "42", "api_hash": "0123456789abcdef0123456789abcdef"]).apiId == 42)
    }
}
