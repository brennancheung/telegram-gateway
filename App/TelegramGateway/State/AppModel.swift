import Foundation
import Observation
import OSLog
import Synchronization

/// `log stream --predicate 'subsystem == "com.brennancheung.telegram-gateway"'` shows these.
let appLog = Logger(subsystem: "com.brennancheung.telegram-gateway", category: "app")

/// Holds the admin token where the HTTP client (any thread) and the model (main actor) can
/// both reach it.
final class TokenBox: Sendable {
    private let storage = Mutex<String?>(nil)
    func get() -> String? { storage.withLock { $0 } }
    func set(_ token: String?) { storage.withLock { $0 = token } }
}

/// Everything the menu bar UI shows, in one observable object. Views read it through the
/// environment; all mutation happens here on the main actor. Network calls go through
/// `client`, which is the real daemon or a `FakeAPIClient`.
@MainActor
@Observable
final class AppModel {
    /// Which screen the popover shows. Decided from facts, never set directly.
    enum Screen: Equatable {
        /// First refresh has not completed.
        case loading
        /// Credentials missing, or the daemon is not answering: show setup and gateway control.
        case setup
        /// Daemon up, but the secrets file has no admin token.
        case tokenMissing
        /// Daemon up, Telegram login not finished.
        case login
        /// Logged in: status, chats, access.
        case main
    }

    enum Tab: String, CaseIterable, Identifiable {
        case status, chats, access
        var id: String { rawValue }
        var title: String {
            switch self {
            case .status: "Status"
            case .chats: "Chats"
            case .access: "Access"
            }
        }
    }

    let client: any APIClient
    let daemon: DaemonManager
    let isPreview: Bool
    private let tokenBox: TokenBox

    // Configuration and token
    var config: GatewayConfig
    var configError: String?
    private(set) var token: String?
    var tokenError: String?

    // Daemon and Telegram state
    private(set) var initialised = false
    private(set) var reachable = false
    private(set) var health: Health?
    private(set) var status: AdminStatus?
    private(set) var lastRefresh: Date?
    var lastError: String?

    // Login
    var auth: AuthInfo?
    var loginError: String?
    var loginBusy = false

    // Chats
    var chats: [Chat] = []
    var folders: [Folder] = []
    var monitored: MonitoredChats?
    var chatsLoading = false
    var chatsError: String?

    // Access
    var requests: [AccessRequest] = []
    var grants: [Grant] = []
    var accessError: String?
    /// The request whose approval screen is open.
    var approving: AccessRequest?

    // UI
    var tab: Tab = .status
    var isPanelOpen = false
    /// The owner asked for the setup screen from the menu even though everything works.
    var showSetup = false

    private var pollTask: Task<Void, Never>?

    init(client: any APIClient, daemon: DaemonManager, config: GatewayConfig, tokenBox: TokenBox = TokenBox(), isPreview: Bool = false) {
        self.client = client
        self.daemon = daemon
        self.config = config
        self.tokenBox = tokenBox
        self.isPreview = isPreview
    }

    // MARK: Factories

    /// The app as the owner runs it: real config file, real secrets file, real daemon.
    static func live() -> AppModel {
        var configError: String?
        let config: GatewayConfig
        do {
            config = try GatewayConfig.load()
        } catch {
            config = GatewayConfig()
            configError = error.localizedDescription
        }
        let box = TokenBox()
        let client = HTTPAPIClient(baseURL: config.baseURL, token: { box.get() })
        let model = AppModel(client: client, daemon: DaemonManager(), config: config, tokenBox: box)
        model.configError = configError
        return model
    }

    /// A model over `FakeAPIClient` for previews and tests. `credentials: false` starts on
    /// the setup screen.
    static func preview(_ scenario: FakeAPIClient.Scenario = .loggedIn, credentials: Bool = true, token: Bool = true, has2FA: Bool = true) -> AppModel {
        let box = TokenBox()
        if token { box.set("tgw_previewtoken") }
        let config = credentials ? GatewayConfig(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef", daemonPath: "/tmp/GatewayDaemon") : GatewayConfig()
        let model = AppModel(client: FakeAPIClient(scenario: scenario, has2FA: has2FA), daemon: DaemonManager(previewMode: true), config: config, tokenBox: box, isPreview: true)
        model.token = box.get()
        return model
    }

    // MARK: Derived state

    var screen: Screen {
        guard initialised else { return .loading }
        if showSetup || !config.hasCredentials || !reachable { return .setup }
        guard token != nil else { return .tokenMissing }
        guard let health else { return .setup }
        return health.tdlib.authState.isLoggedIn ? .main : .login
    }

    var authState: AuthState { auth?.authState ?? health?.tdlib.authState ?? .unknown }
    var pendingRequestCount: Int { requests.count }
    var monitoredCount: Int { monitored?.effectiveChatIds.count ?? status?.monitoredChatCount ?? 0 }
    var chatsByID: [String: Chat] { Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    // MARK: Polling

    /// Starts the background refresh. Every 15s while the panel is closed (enough for the
    /// pending-request badge), every 5s while it is open.
    func start() {
        guard pollTask == nil else { return }
        appLog.notice("start: base URL \(self.config.baseURL.absoluteString, privacy: .public), credentials \(self.config.hasCredentials)")
        daemon.locate(config: config)
        daemon.refreshAgentState()
        appLog.notice("launchd agent: \(self.daemon.agentState.label, privacy: .public); daemon binary: \(self.daemon.daemonURL?.path ?? "none", privacy: .public)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds: Double = self.isPanelOpen ? 5 : 15
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func panelOpened() {
        isPanelOpen = true
        daemon.refreshAgentState()
        Task { await refresh() }
    }

    func panelClosed() {
        isPanelOpen = false
    }

    /// One round: token, health, then status and pending requests if possible.
    func refresh() async {
        let started = Date()
        if !isPreview { loadToken() }
        let tokenTime = Date().timeIntervalSince(started)
        do {
            health = try await client.health()
            appLog.notice("refresh: token read \(tokenTime, format: .fixed(precision: 2))s, health \(Date().timeIntervalSince(started) - tokenTime, format: .fixed(precision: 2))s, auth \(self.health?.tdlib.authState.rawValue ?? "", privacy: .public)")
            reachable = true
            lastError = nil
        } catch {
            reachable = false
            health = nil
            status = nil
            lastError = (error as? APIClientError)?.errorDescription ?? error.localizedDescription
            appLog.error("health failed: \(self.lastError ?? "", privacy: .public)")
        }
        defer {
            initialised = true
            lastRefresh = Date()
        }
        guard reachable, token != nil else { return }
        do {
            status = try await client.adminStatus()
            tokenError = nil
        } catch let error as APIClientError where error.apiCode == "invalid_token" || error.apiCode == "missing_token" {
            tokenError = "The gateway rejected the stored admin token. The daemon may have regenerated it; restart the app after `tgw` shows the new one."
        } catch {
            lastError = error.localizedDescription
        }
        if authState.isLoggedIn {
            if let list = try? await client.accessRequests() { requests = list }
            if isPanelOpen, tab == .access, let list = try? await client.grants() { grants = list }
        }
    }

    /// Reads `secrets.json` (or, opt-in, the Keychain). Never called for previews or tests.
    func loadToken() {
        do {
            token = try AdminToken.read(config: config)
            tokenBox.set(token)
            tokenError = nil
        } catch {
            token = nil
            tokenBox.set(nil)
            tokenError = error.localizedDescription
            appLog.error("admin token: \(self.tokenError ?? "", privacy: .public)")
        }
    }

    // MARK: Setup

    func saveCredentials(apiId: Int, apiHash: String) {
        do {
            config = try GatewayConfig.merge(["api_id": apiId, "api_hash": apiHash])
            configError = nil
        } catch {
            configError = error.localizedDescription
        }
    }

    func reloadConfig() {
        do {
            config = try GatewayConfig.load()
            configError = nil
        } catch {
            configError = error.localizedDescription
        }
    }

    // MARK: Login

    func refreshAuth() async {
        do {
            let info = try await client.auth()
            // Only publish a change: an identical link must not redraw (and flash) the QR.
            if auth != info { auth = info }
            if info.authState.isLoggedIn, health?.tdlib.authState.isLoggedIn == false {
                await refresh()
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    func requestQR() async {
        await login { try await self.client.requestQRLogin() }
    }

    func submitPhone(_ phone: String) async {
        await login { try await self.client.submitPhoneNumber(phone.trimmingCharacters(in: .whitespaces)) }
    }

    func submitCode(_ code: String) async {
        await login { try await self.client.submitCode(code.trimmingCharacters(in: .whitespaces)) }
    }

    func submitPassword(_ password: String) async {
        await login { try await self.client.submitPassword(password) }
    }

    func submitEmail(_ email: String) async {
        await login { try await self.client.submitEmailAddress(email.trimmingCharacters(in: .whitespaces)) }
    }

    func submitEmailCode(_ code: String) async {
        await login { try await self.client.submitEmailCode(code.trimmingCharacters(in: .whitespaces)) }
    }

    private func login(_ action: () async throws -> AuthInfo) async {
        loginBusy = true
        loginError = nil
        defer { loginBusy = false }
        do {
            let info = try await action()
            auth = info
            if info.authState.isLoggedIn { await refresh() }
        } catch let error as APIClientError {
            if case .api(let apiError, _, let hint) = error {
                loginError = apiError.message
                if let hint, var current = auth { current.passwordHint = hint; auth = current }
            } else {
                loginError = error.errorDescription
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    func logout() async {
        loginBusy = true
        defer { loginBusy = false }
        do {
            try await client.logout()
            auth = nil
            chats = []
            folders = []
            monitored = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Chats

    func loadChats() async {
        chatsLoading = true
        chatsError = nil
        defer { chatsLoading = false }
        do {
            async let chatList = client.allChats()
            async let folderList = client.folders()
            async let monitoredSet = client.monitoredChats()
            chats = try await chatList
            folders = try await folderList
            monitored = try await monitoredSet
        } catch {
            chatsError = error.localizedDescription
        }
    }

    /// Replaces the monitored set (docs/api.md `PUT /v1/admin/monitored-chats`).
    func saveMonitored(chatIds: [String], folderIds: [String]) async -> Bool {
        chatsError = nil
        do {
            monitored = try await client.setMonitoredChats(chatIds: chatIds, folderIds: folderIds)
            let effective = Set(monitored?.effectiveChatIds ?? [])
            chats = chats.map { var chat = $0; chat.isMonitored = effective.contains(chat.id); return chat }
            folders = folders.map { var folder = $0; folder.isMonitored = folderIds.contains(folder.id); return folder }
            return true
        } catch {
            chatsError = error.localizedDescription
            return false
        }
    }

    // MARK: Access

    func loadAccess() async {
        do {
            async let pending = client.accessRequests()
            async let granted = client.grants()
            requests = try await pending
            grants = try await granted
            accessError = nil
        } catch {
            accessError = error.localizedDescription
        }
    }

    /// Approves a request. Chats in `alsoMonitor` are added to the monitored set first
    /// (docs/grants.md: approval never exceeds the monitored set, and the app monitors first
    /// so the owner experiences one click).
    func approve(_ request: AccessRequest, selection: GrantChatSelection, scopes: [String], alsoMonitor: [String]) async -> Bool {
        accessError = nil
        do {
            if !alsoMonitor.isEmpty {
                let current = try await client.monitoredChats()
                let chatIds = Array(Set(current.chatIds).union(alsoMonitor)).sorted()
                monitored = try await client.setMonitoredChats(chatIds: chatIds, folderIds: current.folderIds)
            }
            _ = try await client.approve(requestId: request.requestId, selection: selection, scopes: scopes)
            approving = nil
            await loadAccess()
            return true
        } catch {
            accessError = error.localizedDescription
            return false
        }
    }

    func deny(_ request: AccessRequest) async {
        do {
            try await client.deny(requestId: request.requestId, reason: nil)
            await loadAccess()
        } catch {
            accessError = error.localizedDescription
        }
    }

    func revoke(_ grant: Grant) async {
        do {
            try await client.revoke(grantId: grant.id)
            await loadAccess()
        } catch {
            accessError = error.localizedDescription
        }
    }

    func resumeWebhook(_ grant: Grant) async {
        do {
            try await client.resumeWebhook(grantId: grant.id)
            await loadAccess()
        } catch {
            accessError = error.localizedDescription
        }
    }

    // MARK: Gateway control

    func startGateway() {
        daemon.register(config: config)
        reloadConfig()
        Task { await refresh() }
    }

    func runInForeground() {
        daemon.runInForeground(config: config)
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }

    func restartGateway() {
        daemon.restart(config: config)
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }
}
