import Foundation

/// An in-memory gateway for previews and tests. It behaves like the daemon in docs/api.md
/// closely enough to drive every screen: the login state machine, chat list and folders,
/// the monitored set, access requests turning into grants, revocation, and a QR link that
/// rotates so the QR refresh path is exercised.
actor FakeAPIClient: APIClient {
    /// The situation a preview or test starts in.
    enum Scenario: Sendable {
        /// The daemon is not running: every call fails with `.unreachable`.
        case unreachable
        /// Running, never logged in (`wait_phone_number`).
        case loggedOut
        /// Running, QR displayed.
        case waitingForQR
        /// Running, code sent to a phone.
        case waitingForCode
        /// Running, 2FA password needed.
        case waitingForPassword
        /// Logged in, with chats, one pending request and two grants.
        case loggedIn
        /// Logged in, nothing monitored, no requests, no grants.
        case loggedInEmpty
    }

    private var scenario: Scenario
    private var authState: AuthState
    private var qrCounter = 0
    private var authReads = 0
    private var phoneHint: String?
    private let has2FA: Bool
    private var chats: [Chat]
    private var folders: [Folder]
    private var monitored: MonitoredChats
    private var requests: [AccessRequest]
    private var grantsStore: [Grant]
    private var headSeq = 4812
    private let startedAt = Date().addingTimeInterval(-5 * 3600)
    private var nextGrant = 1

    /// Set to fail every call with this error (tests of the error paths).
    var failure: APIClientError?

    init(scenario: Scenario = .loggedIn, has2FA: Bool = true) {
        self.scenario = scenario
        self.has2FA = has2FA
        switch scenario {
        case .unreachable, .loggedOut: authState = .waitPhoneNumber
        case .waitingForQR: authState = .waitQRConfirmation
        case .waitingForCode: authState = .waitCode; phoneHint = "+1 555 ••• 4567"
        case .waitingForPassword: authState = .waitPassword
        case .loggedIn, .loggedInEmpty: authState = .ready
        }
        chats = Fixtures.chats
        folders = Fixtures.folders
        switch scenario {
        case .loggedIn:
            monitored = MonitoredChats(chatIds: ["-1001234567890"], folderIds: ["3"], effectiveChatIds: [])
            requests = Fixtures.requests
            grantsStore = Fixtures.grants
        default:
            monitored = MonitoredChats(chatIds: [], folderIds: [], effectiveChatIds: [])
            requests = []
            grantsStore = []
        }
        (monitored, chats, folders, grantsStore) = Self.recompute(monitored: monitored, chats: chats, folders: folders, grants: grantsStore)
    }

    // MARK: Test hooks

    func setFailure(_ error: APIClientError?) { failure = error }

    /// Simulates the owner scanning the QR code on the phone.
    func simulateQRScanned() {
        guard authState == .waitQRConfirmation else { return }
        authState = has2FA ? .waitPassword : .ready
    }

    func addPendingRequest(_ request: AccessRequest) { requests.append(request) }

    // MARK: Health and status

    func health() async throws -> Health {
        try gate()
        return Health(status: authState == .ready ? "ok" : "degraded", version: "0.1.0-fake", startedAt: startedAt, time: Date(), tdlib: tdlib, headSeq: headSeq)
    }

    func adminStatus() async throws -> AdminStatus {
        try gate()
        let account = authState == .ready ? Account(userId: "123456789", displayName: "Brennan Cheung", username: "brennan", phoneLast4: "4567") : nil
        let paused = grantsStore.filter { $0.webhook?.state == .paused }.count
        let active = grantsStore.filter { $0.webhook?.state == .active }.count
        let retrying = grantsStore.filter { $0.webhook?.state == .retrying }.count
        return AdminStatus(
            status: authState == .ready ? "ok" : "degraded", version: "0.1.0-fake", startedAt: startedAt, time: Date(),
            tdlib: tdlib, headSeq: headSeq, account: account,
            monitoredChatCount: monitored.effectiveChatIds.count, grantCount: grantsStore.count,
            webhooks: WebhookCounts(active: active, retrying: retrying, paused: paused),
            eventsLastHour: 37, oldestSeq: 1, mediaCacheBytes: 128 * 1024 * 1024,
            backfill: BackfillStatus(inProgress: false, chatsPending: 0))
    }

    private var tdlib: TDLibState {
        TDLibState(authState: authState, connectionState: authState == .ready ? .ready : .connecting)
    }

    // MARK: Login

    func auth() async throws -> AuthInfo {
        try gate()
        authReads += 1
        // A real link changes every ~30s; here every 8 reads (16s at the 2s poll).
        if authState == .waitQRConfirmation, authReads % 8 == 0 { qrCounter += 1 }
        return authInfo
    }

    private var authInfo: AuthInfo {
        switch authState {
        case .waitQRConfirmation:
            AuthInfo(authState: authState, qrLink: "tg://login?token=" + Fixtures.qrTokens[qrCounter % Fixtures.qrTokens.count])
        case .waitCode:
            AuthInfo(authState: authState, phoneHint: phoneHint, codeType: "telegram_message")
        case .waitPassword:
            AuthInfo(authState: authState, passwordHint: "pet")
        default:
            AuthInfo(authState: authState)
        }
    }

    func requestQRLogin() async throws -> AuthInfo {
        try gate()
        qrCounter += 1
        authState = .waitQRConfirmation
        return authInfo
    }

    func submitPhoneNumber(_ phoneNumber: String) async throws -> AuthInfo {
        try gate()
        guard phoneNumber.hasPrefix("+"), phoneNumber.count >= 8 else {
            throw invalid("phone_number", "Phone number must be in international format, e.g. +15551234567.")
        }
        phoneHint = phoneNumber
        authState = .waitCode
        return authInfo
    }

    func submitCode(_ code: String) async throws -> AuthInfo {
        try gate()
        guard code == "12345" else { throw invalid("code", "The code is wrong. Try 12345 in the fake gateway.") }
        authState = has2FA ? .waitPassword : .ready
        return authInfo
    }

    func submitPassword(_ password: String) async throws -> AuthInfo {
        try gate()
        guard password == "hunter2" else {
            throw APIClientError.api(APIError(code: "invalid_request", message: "The password is wrong.", details: ["field": .string("password"), "reason": .string("wrong_password")]), status: 400, passwordHint: "pet")
        }
        authState = .ready
        return authInfo
    }

    func submitEmailAddress(_ email: String) async throws -> AuthInfo {
        try gate()
        authState = .waitEmailCode
        return authInfo
    }

    func submitEmailCode(_ code: String) async throws -> AuthInfo {
        try gate()
        authState = has2FA ? .waitPassword : .ready
        return authInfo
    }

    func logout() async throws {
        try gate()
        authState = .waitPhoneNumber
    }

    // MARK: Chats

    func allChats() async throws -> [Chat] {
        try gate()
        try requireLogin()
        return chats
    }

    func folders() async throws -> [Folder] {
        try gate()
        try requireLogin()
        return folders
    }

    func monitoredChats() async throws -> MonitoredChats {
        try gate()
        return monitored
    }

    func setMonitoredChats(chatIds: [String], folderIds: [String]) async throws -> MonitoredChats {
        try gate()
        for id in chatIds where !chats.contains(where: { $0.id == id }) {
            throw APIClientError.api(APIError(code: "chat_not_monitorable", message: "Unknown chat \(id).", details: ["chat_id": .string(id)]), status: 400, passwordHint: nil)
        }
        monitored = MonitoredChats(chatIds: chatIds, folderIds: folderIds, effectiveChatIds: [])
        recomputeMonitored()
        return monitored
    }

    private func recomputeMonitored() {
        (monitored, chats, folders, grantsStore) = Self.recompute(monitored: monitored, chats: chats, folders: folders, grants: grantsStore)
    }

    /// Derives `effective_chat_ids`, `is_monitored` flags and every grant's effective set
    /// from the monitored set, the way the daemon does.
    private static func recompute(monitored: MonitoredChats, chats: [Chat], folders: [Folder], grants: [Grant]) -> (MonitoredChats, [Chat], [Folder], [Grant]) {
        var effective = Set(monitored.chatIds)
        for folder in folders where monitored.folderIds.contains(folder.id) {
            effective.formUnion(folder.chatIds)
        }
        var monitored = monitored
        monitored.effectiveChatIds = chats.map(\.id).filter { effective.contains($0) }
        let chats = chats.map { var chat = $0; chat.isMonitored = effective.contains(chat.id); return chat }
        let folders = folders.map { var folder = $0; folder.isMonitored = monitored.folderIds.contains(folder.id); return folder }
        let grants = grants.map { var grant = $0; grant.effectiveChatIds = effectiveIds(for: grant.chats, monitored: monitored, folders: folders); return grant }
        return (monitored, chats, folders, grants)
    }

    private func effectiveIds(for chats: GrantChats) -> [String] {
        Self.effectiveIds(for: chats, monitored: monitored, folders: folders)
    }

    private static func effectiveIds(for chats: GrantChats, monitored: MonitoredChats, folders: [Folder]) -> [String] {
        let granted: Set<String>
        if chats.isFolder, let folder = folders.first(where: { $0.id == chats.folderId }) {
            granted = Set(folder.chatIds)
        } else {
            granted = Set(chats.chatIds ?? [])
        }
        return monitored.effectiveChatIds.filter { granted.contains($0) }
    }

    // MARK: Access requests and grants

    func accessRequests() async throws -> [AccessRequest] {
        try gate()
        return requests.filter { $0.status == .pending }
    }

    func approve(requestId: String, selection: GrantChatSelection, scopes: [String]?) async throws -> Grant {
        try gate()
        guard let index = requests.firstIndex(where: { $0.requestId == requestId }) else {
            throw APIClientError.api(APIError(code: "not_found", message: "No such request.", details: [:]), status: 404, passwordHint: nil)
        }
        let request = requests[index]
        guard request.status == .pending else {
            throw APIClientError.api(APIError(code: "already_resolved", message: "Already \(request.status.rawValue).", details: ["status": .string(request.status.rawValue)]), status: 409, passwordHint: nil)
        }
        let grantedScopes = scopes ?? request.scopes
        for scope in grantedScopes where !request.scopes.contains(scope) {
            throw APIClientError.api(APIError(code: "scope_not_requested", message: "\(scope) was not requested.", details: ["scope": .string(scope)]), status: 400, passwordHint: nil)
        }
        let grantChats: GrantChats
        switch selection {
        case .chats(let ids):
            for id in ids where !monitored.effectiveChatIds.contains(id) {
                throw APIClientError.api(APIError(code: "chat_not_monitored", message: "Chat \(id) is not monitored.", details: ["chat_id": .string(id)]), status: 400, passwordHint: nil)
            }
            grantChats = GrantChats(mode: "list", chatIds: ids, folderId: nil, folderTitle: nil)
        case .folder(let folderId):
            guard let folder = folders.first(where: { $0.id == folderId }), folder.isMonitored else {
                throw APIClientError.api(APIError(code: "folder_not_monitored", message: "Folder \(folderId) is not monitored.", details: ["folder_id": .string(folderId)]), status: 400, passwordHint: nil)
            }
            grantChats = GrantChats(mode: "folder", chatIds: nil, folderId: folder.id, folderTitle: folder.title)
        }
        let webhook = request.webhookUrl.map {
            WebhookStatus(url: $0, state: .active, cursorSeq: headSeq, pendingEvents: 0, lastDeliveryAt: nil, lastError: nil, pausedAt: nil)
        }
        let grant = Grant(
            id: "grant_fake\(nextGrant)", app: AppInfo(name: request.name, description: request.description),
            scopes: grantedScopes, chats: grantChats, effectiveChatIds: effectiveIds(for: grantChats),
            webhook: webhook, createdAt: Date(), lastSeenAt: nil, revokedAt: nil)
        nextGrant += 1
        grantsStore.append(grant)
        requests[index].status = .approved
        return grant
    }

    func deny(requestId: String, reason: String?) async throws {
        try gate()
        guard let index = requests.firstIndex(where: { $0.requestId == requestId }) else { return }
        requests[index].status = .denied
    }

    func grants() async throws -> [Grant] {
        try gate()
        return grantsStore.filter { $0.revokedAt == nil }
    }

    func grantDetail(id: String) async throws -> GrantDetail {
        try gate()
        guard let grant = grantsStore.first(where: { $0.id == id }) else {
            throw APIClientError.api(APIError(code: "not_found", message: "No such grant.", details: [:]), status: 404, passwordHint: nil)
        }
        return GrantDetail(grant: grant, stats: GrantStats(eventsDelivered24h: 812, websocketConnections: 1))
    }

    func revoke(grantId: String) async throws {
        try gate()
        guard let index = grantsStore.firstIndex(where: { $0.id == grantId }) else { return }
        grantsStore[index].revokedAt = Date()
    }

    func resumeWebhook(grantId: String) async throws {
        try gate()
        guard let index = grantsStore.firstIndex(where: { $0.id == grantId }), var webhook = grantsStore[index].webhook else {
            throw APIClientError.api(APIError(code: "webhook_not_configured", message: "No webhook.", details: [:]), status: 409, passwordHint: nil)
        }
        guard webhook.state == .paused else {
            throw APIClientError.api(APIError(code: "webhook_not_paused", message: "Webhook is \(webhook.state.rawValue).", details: ["state": .string(webhook.state.rawValue)]), status: 409, passwordHint: nil)
        }
        webhook.state = .active
        webhook.pausedAt = nil
        webhook.lastError = nil
        grantsStore[index].webhook = webhook
    }

    func deliveries(grantId: String, limit: Int) async throws -> [Delivery] {
        try gate()
        return Array(Fixtures.deliveries.prefix(limit))
    }

    // MARK: Helpers

    private func gate() throws {
        if let failure { throw failure }
        if case .unreachable = scenario { throw APIClientError.unreachable("Could not connect to the server.") }
    }

    private func requireLogin() throws {
        guard authState == .ready else {
            throw APIClientError.api(APIError(code: "not_logged_in", message: "The gateway has no Telegram session yet.", details: ["auth_state": .string(authState.rawValue)]), status: 503, passwordHint: nil)
        }
    }

    private func invalid(_ field: String, _ message: String) -> APIClientError {
        .api(APIError(code: "invalid_request", message: message, details: ["field": .string(field)]), status: 400, passwordHint: nil)
    }
}

/// Sample data shaped like the examples in docs/api.md.
enum Fixtures {
    static let qrTokens = [
        "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
        "IB8eHRwbGhkYFxYVFBMSERAPDg0MCwoJCAcGBQQDAgE",
        "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZmdoaWo",
    ]

    static let chats: [Chat] = [
        Chat(id: "-1001234567890", type: .channel, title: "Acme Product Updates", username: "acmeupdates", memberCount: 12840, isMonitored: false, photo: nil),
        Chat(id: "-1001987654321", type: .supergroup, title: "Acme Support", username: "acmesupport", memberCount: 3120, isMonitored: false, photo: nil),
        Chat(id: "-1001111111111", type: .channel, title: "Industry News", username: "industrynews", memberCount: 98000, isMonitored: false, photo: nil),
        Chat(id: "-1002222222222", type: .supergroup, title: "Swift Forums Digest", username: nil, memberCount: 540, isMonitored: false, photo: nil),
        Chat(id: "-987654321", type: .basicGroup, title: "Family", username: nil, memberCount: 6, isMonitored: false, photo: nil),
        Chat(id: "123456789", type: .private, title: "Alice", username: "alice", memberCount: nil, isMonitored: false, photo: nil),
        Chat(id: "-1003333333333", type: .channel, title: "Volgenic Announcements", username: "volgenic", memberCount: 2210, isMonitored: false, photo: nil),
    ]

    static let folders: [Folder] = [
        Folder(id: "3", title: "Product", chatIds: ["-1001234567890", "-1001987654321"], isMonitored: false),
        Folder(id: "5", title: "News", chatIds: ["-1001111111111", "-1003333333333"], isMonitored: false),
    ]

    static let requests: [AccessRequest] = [
        AccessRequest(
            requestId: "req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP", status: .pending,
            name: "Community Analytics", description: "Classifies messages in product channels and counts topics per day.",
            scopes: ["messages:read", "history:read", "chats:read"],
            requestedChats: .list(["-1001234567890", "-1001111111111"]),
            requestedChatsStatus: [
                RequestedChatStatus(chatId: "-1001234567890", title: "Acme Product Updates", isMonitored: true),
                RequestedChatStatus(chatId: "-1001111111111", title: "Industry News", isMonitored: false),
            ],
            webhookUrl: "https://analytics.example.com/tgw/events",
            createdAt: Date().addingTimeInterval(-120), expiresAt: Date().addingTimeInterval(13 * 60)),
    ]

    static let grants: [Grant] = [
        Grant(
            id: "grant_Ab3dE5fG7hJ9kL1m", app: AppInfo(name: "Support Triage", description: "Flags support questions and routes them."),
            scopes: ["messages:read", "chats:read"],
            chats: GrantChats(mode: "folder", chatIds: nil, folderId: "3", folderTitle: "Product"),
            effectiveChatIds: ["-1001234567890", "-1001987654321"],
            webhook: WebhookStatus(url: "https://triage.example.com/tgw", state: .active, cursorSeq: 4812, pendingEvents: 0, lastDeliveryAt: Date().addingTimeInterval(-90), lastError: nil, pausedAt: nil),
            createdAt: Date().addingTimeInterval(-86400 * 3), lastSeenAt: Date().addingTimeInterval(-30), revokedAt: nil),
        Grant(
            id: "grant_Xy9zW8vU7tS6rQ5p", app: AppInfo(name: "Archive", description: "Keeps a searchable copy of product channels."),
            scopes: ["messages:read", "history:read", "media:read", "chats:read"],
            chats: GrantChats(mode: "list", chatIds: ["-1001234567890"], folderId: nil, folderTitle: nil),
            effectiveChatIds: ["-1001234567890"],
            webhook: WebhookStatus(url: "https://archive.example.com/hooks/tgw", state: .paused, cursorSeq: 4610, pendingEvents: 202, lastDeliveryAt: Date().addingTimeInterval(-86400 * 2), lastError: "connection refused", pausedAt: Date().addingTimeInterval(-3600)),
            createdAt: Date().addingTimeInterval(-86400 * 10), lastSeenAt: Date().addingTimeInterval(-86400 * 2), revokedAt: nil),
    ]

    static let deliveries: [Delivery] = [
        Delivery(deliveryId: "dlv_8Kp2mQ9xR4tV7wY1", firstSeq: 4810, lastSeq: 4812, eventCount: 2, attempt: 1, status: .succeeded, httpStatus: 200, error: nil, sentAt: Date().addingTimeInterval(-90), completedAt: Date().addingTimeInterval(-89)),
        Delivery(deliveryId: "dlv_1Aa2Bb3Cc4Dd5Ee6", firstSeq: 4600, lastSeq: 4609, eventCount: 10, attempt: 31, status: .failed, httpStatus: nil, error: "connection refused", sentAt: Date().addingTimeInterval(-3700), completedAt: Date().addingTimeInterval(-3690)),
    ]
}
