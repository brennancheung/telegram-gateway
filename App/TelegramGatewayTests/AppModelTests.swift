import Foundation
import Testing
@testable import TelegramGateway

/// The model's screen decisions and the flows the screens drive, all against the fake.
/// Nothing here reads the Keychain, the real secrets file, launchd or the app's defaults.
@Suite("AppModel over FakeAPIClient")
@MainActor
struct AppModelTests {
    // MARK: Screens and header

    @Test("Screen follows the facts")
    func screens() async {
        let noKey = AppModel.preview(.loggedIn, credentials: false)
        await noKey.refresh()
        #expect(noKey.screen == .connect)

        let firstRunDown = AppModel.preview(.unreachable, onboarded: false)
        await firstRunDown.refresh()
        #expect(firstRunDown.screen == .connect)

        let down = AppModel.preview(.unreachable)
        await down.refresh()
        #expect(down.screen == .gatewayDown)
        #expect(!down.reachable)

        let noToken = AppModel.preview(.loggedIn, token: false)
        await noToken.refresh()
        #expect(noToken.screen == .keyMissing)

        let loggedOut = AppModel.preview(.loggedOut)
        await loggedOut.refresh()
        #expect(loggedOut.screen == .login)

        let ready = AppModel.preview(.loggedIn)
        #expect(ready.screen == .loading)
        await ready.refresh()
        #expect(ready.screen == .main)
        #expect(ready.accountName == "@brennan")
        #expect(ready.pendingRequestCount == 1)
        #expect(ready.grants.count == 2)

        ready.editingKey = true
        #expect(ready.screen == .connect)
    }

    @Test("Header: one phrase per state")
    func headlines() async {
        func headline(_ scenario: FakeAPIClient.Scenario, credentials: Bool = true, token: Bool = true, onboarded: Bool = true) async -> AppModel.Headline {
            let model = AppModel.preview(scenario, credentials: credentials, token: token, onboarded: onboarded)
            await model.refresh()
            return model.headline
        }
        #expect(AppModel.preview(.loggedIn).headline == .init(tone: .neutral, phrase: "Connecting…"))
        #expect(await headline(.loggedIn) == .init(tone: .ok, phrase: "Connected as @brennan"))
        #expect(await headline(.reconnecting) == .init(tone: .attention, phrase: "Reconnecting to Telegram…"))
        #expect(await headline(.waitingForQR) == .init(tone: .attention, phrase: "Scan the code to sign in"))
        #expect(await headline(.waitingForPassword) == .init(tone: .attention, phrase: "Finish signing in"))
        #expect(await headline(.unreachable) == .init(tone: .failed, phrase: "Gateway not running"))
        #expect(await headline(.unreachable, credentials: false, onboarded: false) == .init(tone: .neutral, phrase: "Not set up yet"))
        #expect(await headline(.loggedIn, token: false) == .init(tone: .failed, phrase: "Gateway needs attention"))
    }

    @Test("Overview hero: calm when fine, says what is wrong and offers one action otherwise")
    func hero() async {
        let fine = AppModel.preview(.loggedIn)
        await fine.refresh()
        #expect(fine.hero == .init(tone: .neutral, title: "Monitoring 3 chats", detail: "37 messages in the last hour · 4,812 total", action: nil))

        let none = AppModel.preview(.loggedInEmpty)
        await none.refresh()
        #expect(none.hero.tone == .attention)
        #expect(none.hero.title == "Not monitoring any chats")
        #expect(none.hero.action == .chooseChats)

        let reconnecting = AppModel.preview(.reconnecting)
        await reconnecting.refresh()
        #expect(reconnecting.hero.tone == .attention)
        #expect(reconnecting.hero.action == nil)

        let down = AppModel.preview(.unreachable)
        await down.refresh()
        #expect(down.hero.tone == .failed)
        #expect(down.hero.title == "Gateway not running")
        #expect(down.hero.action == .startGateway)
    }

    @Test("Needs you: pending requests and stopped deliveries, nothing when all is fine")
    func needsYou() async {
        let busy = AppModel.preview(.loggedIn)
        await busy.refresh()
        #expect(busy.needsYou.count == 2)
        guard case .request(let request) = busy.needsYou[0], case .webhook(let grant) = busy.needsYou[1] else {
            Issue.record("expected a request then a webhook")
            return
        }
        #expect(request.name == "Community Analytics")
        #expect(grant.app.name == "Archive")
        #expect(grant.state.tone == .attention)
        #expect(grant.state.text == "Paused")

        let quiet = AppModel.preview(.loggedInQuiet)
        await quiet.refresh()
        #expect(quiet.needsYou.isEmpty)
        #expect(quiet.grants.allSatisfy { $0.state.tone == .ok })
        #expect(quiet.grants[1].summary == "1 chat · new messages")
        #expect(quiet.grants[0].summary == "Product folder · new messages, chat names")
    }

    // MARK: Step 1

    @Test("Continue saves the key and starts the gateway; a gateway that never answers is reported with a reason")
    func connectFailure() async {
        let model = AppModel.preview(.unreachable, credentials: false, token: false, onboarded: false)
        await model.refresh()
        #expect(model.screen == .connect)
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(model.config.hasCredentials)
        // Tried the login-item route, then fell back to running it inside the app.
        #expect(model.daemon.isForegroundRunning)
        #expect(model.daemon.agentState == .notRegistered)
        guard case .failed(let reason) = model.startPhase else {
            Issue.record("expected the start to fail, got \(model.startPhase)")
            return
        }
        #expect(reason == "It didn't answer on port 41414.")
        #expect(model.screen == .connect)
        #expect(model.headline.phrase == "Gateway not running")
    }

    @Test("Continue with a gateway that answers moves on to sign-in")
    func connectSuccess() async {
        let model = AppModel.preview(.loggedOut, credentials: false, onboarded: false)
        await model.refresh()
        #expect(model.screen == .connect)
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(model.startPhase == .idle)
        #expect(model.screen == .login)
    }

    // MARK: Step 2

    @Test("QR sign-in: link, rotation, scan, password; first sign-in lands on Chats")
    func qrLogin() async throws {
        let model = AppModel.preview(.loggedOut, has2FA: true, onboarded: false)
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
        #expect(model.loginError == "That password isn't right.")
        #expect(model.authState == .waitPassword)
        await model.submitPassword("hunter2")
        #expect(model.loginError == nil)
        #expect(model.screen == .main)
        #expect(model.tab == .chats)
        #expect(!model.onboardingDone)
    }

    @Test("Phone sign-in: phone → code → signed in; a returning owner stays on Overview")
    func phoneLogin() async {
        let model = AppModel.preview(.loggedOut, has2FA: false)
        await model.refresh()
        model.loginMode = .phone
        await model.submitPhone("12345")
        #expect(model.loginError != nil)
        await model.submitPhone("+15551234567")
        #expect(model.authState == .waitCode)
        #expect(model.auth?.phoneHint == "+15551234567")
        await model.submitCode("00000")
        #expect(model.loginError != nil)
        await model.submitCode("12345")
        #expect(model.screen == .main)
        #expect(model.tab == .overview)
        #expect(model.loginMode == .qr)
        await model.logout()
        #expect(model.screen == .login)
    }

    // MARK: Chats

    @Test("Monitored draft: ticks are local until Save; folders cover their chats")
    func monitoredDraft() async {
        let model = AppModel.preview(.loggedInEmpty, onboarded: false)
        await model.refresh()
        await model.loadChats()
        #expect(model.chats.count == Fixtures.chats.count)
        #expect(!model.isDraftDirty)
        #expect(model.draftEffectiveCount == 0)

        model.setChat("-1001111111111", monitored: true)
        model.setFolder("3", monitored: true)
        #expect(model.isDraftDirty)
        #expect(model.draftChangeCount == 2)
        #expect(model.draftEffectiveCount == 3)
        #expect(model.coveringFolder(for: "-1001987654321")?.title == "Product")
        #expect(model.isChatTicked("-1001987654321"))
        #expect(model.coveringFolder(for: "-1001111111111") == nil)
        #expect(model.monitoredCount == 0)

        model.revertDraft()
        #expect(!model.isDraftDirty)
        #expect(model.draftChangeCount == 0)

        model.setChat("-1001111111111", monitored: true)
        model.setFolder("3", monitored: true)
        let saved = await model.saveDraft()
        #expect(saved)
        #expect(!model.isDraftDirty)
        #expect(Set(model.monitored?.effectiveChatIds ?? []) == ["-1001111111111", "-1001234567890", "-1001987654321"])
        #expect(model.chats.first { $0.id == "-1001987654321" }?.isMonitored == true)
        #expect(model.folders.first { $0.id == "3" }?.isMonitored == true)
        // Choosing chats finishes first-run setup.
        #expect(model.onboardingDone)
        #expect(model.hero.title == "Monitoring 3 chats")
    }

    @Test("A rejected save keeps the draft and reports the error")
    func monitoredSaveFailure() async {
        let model = AppModel.preview(.loggedInEmpty)
        await model.refresh()
        await model.loadChats()
        model.setChat("nope", monitored: true)
        let saved = await model.saveDraft()
        #expect(!saved)
        #expect(model.chatsError != nil)
        #expect(model.isDraftDirty)
    }

    // MARK: Apps

    @Test("Approval starts with what the app asked for")
    func approvalDraft() async throws {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        model.beginApproval(model.requests[0])
        let draft = try #require(model.approval)
        #expect(model.overlay == .approve)
        #expect(draft.chatIds == ["-1001234567890", "-1001987654321", "-1003333333333"])
        #expect(draft.scopes == ["messages:read", "history:read", "chats:read"])
        #expect(model.approvalChatIds(draft) == ["-1001234567890", "-1001987654321", "-1003333333333"])
        #expect(model.otherMonitoredCount(draft) == 1)
        #expect(model.approvalSummary(draft) == "3 chats · 3 permissions")
        #expect(model.canApprove(draft))

        model.approval?.showOtherChats = true
        #expect(model.approvalChatIds(try #require(model.approval)).last == "-1001111111111")

        model.approval?.scopes = []
        #expect(!model.canApprove(try #require(model.approval)))
        model.approval?.scopes = ["messages:read"]
        model.approval?.chatIds = []
        #expect(!model.canApprove(try #require(model.approval)))

        model.approval?.followFolder = true
        #expect(!model.canApprove(try #require(model.approval)))
        model.approval?.folderId = "3"
        #expect(model.canApprove(try #require(model.approval)))
        #expect(model.approvalSummary(try #require(model.approval)) == "Product folder · 1 permission")

        model.cancelApproval()
        #expect(model.approval == nil)
        #expect(model.overlay == nil)
        #expect(model.requests.count == 1)
    }

    @Test("Approve monitors a ticked chat that was not monitored, narrows permissions, creates the grant")
    func approve() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        model.beginApproval(model.requests[0])
        model.approval?.chatIds.remove("-1001987654321")
        model.approval?.scopes.remove("history:read")
        let ok = await model.approve()
        #expect(ok)
        #expect(model.overlay == nil)
        #expect(model.requests.isEmpty)
        #expect(model.grants.count == 3)
        let grant = model.grants.last
        #expect(grant?.scopes == ["messages:read", "chats:read"])
        #expect(Set(grant?.effectiveChatIds ?? []) == ["-1001234567890", "-1003333333333"])
        #expect(grant?.webhook?.url == "https://analytics.example.com/tgw/events")
        #expect(model.monitored?.chatIds.contains("-1003333333333") == true)
        #expect(model.chatsByID["-1003333333333"]?.isMonitored == true)
    }

    @Test("Approve with a folder grants the folder")
    func approveFolder() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        model.beginApproval(model.requests[0])
        model.approval?.followFolder = true
        model.approval?.folderId = "3"
        #expect(await model.approve())
        #expect(model.grants.last?.chats.isFolder == true)
        #expect(model.grants.last?.summary == "Product folder · 3 permissions")
        // Nothing new was monitored for a folder grant.
        #expect(model.monitored?.chatIds.contains("-1003333333333") != true)
    }

    @Test("A request for any chats offers every monitored chat")
    func approveAny() async throws {
        let model = AppModel.preview(.loggedInQuiet)
        await model.refresh()
        await model.loadChats()
        let request = AccessRequest(
            requestId: "req_any", status: .pending, name: "Anything", description: "d", scopes: ["messages:read", "messages:send"],
            requestedChats: .any, requestedChatsStatus: nil, webhookUrl: nil, createdAt: Date(), expiresAt: Date().addingTimeInterval(900))
        model.beginApproval(request)
        let draft = try #require(model.approval)
        #expect(draft.chatIds.count == 3)
        #expect(model.approvalChatIds(draft).count == 3)
        #expect(model.otherMonitoredCount(draft) == 0)
        // The reserved send permission is never pre-ticked.
        #expect(draft.scopes == ["messages:read"])
    }

    @Test("Deny, resume delivery, revoke")
    func denyResumeRevoke() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadAccess()
        await model.deny(model.requests[0])
        #expect(model.requests.isEmpty)
        #expect(model.pendingRequestCount == 0)
        let paused = model.grants.first { $0.webhook?.state == .paused }!
        await model.resumeWebhook(paused)
        #expect(model.grant(id: paused.id)?.webhook?.state == .active)
        #expect(model.needsYou.isEmpty)
        model.overlay = .grant(paused.id)
        await model.revoke(paused)
        #expect(model.grants.count == 1)
        #expect(model.overlay == nil)
    }

    // MARK: Files

    @Test("Config merge keeps unknown keys and the locator reads config first")
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
        // The gateway writes base64 of the UTF-8 token.
        let base64 = Data("tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV".utf8).base64EncodedString()
        try Data(#"{"admin-token": "\#(base64)", "tdlib-db-key": "AAAA"}"#.utf8).write(to: file)
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

    @Test("Key validation")
    func credentials() {
        #expect(!GatewayConfig(apiId: nil, apiHash: nil).hasCredentials)
        #expect(!GatewayConfig(apiId: 0, apiHash: "0123456789abcdef0123456789abcdef").hasCredentials)
        #expect(!GatewayConfig(apiId: 1, apiHash: "short").hasCredentials)
        #expect(!GatewayConfig(apiId: 1, apiHash: "0123456789abcdef0123456789abcdeg").hasCredentials)
        #expect(GatewayConfig(apiId: 1, apiHash: "0123456789ABCDEF0123456789abcdef").hasCredentials)
        #expect(GatewayConfig(raw: ["api_id": "42", "api_hash": "0123456789abcdef0123456789abcdef"]).apiId == 42)
    }
}
