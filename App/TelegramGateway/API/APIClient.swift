import Foundation

/// Everything the menu bar app asks the gateway daemon. `HTTPAPIClient` talks to the real
/// daemon over loopback HTTP; `FakeAPIClient` answers from memory for previews and tests.
/// Method names follow docs/api.md; each doc comment names the endpoint.
protocol APIClient: Sendable {
    // Health and status
    /// `GET /v1/health` (unauthenticated).
    func health() async throws -> Health
    /// `GET /v1/admin/status`.
    func adminStatus() async throws -> AdminStatus

    // Login (docs/api.md "Admin: login")
    /// `GET /v1/admin/auth`.
    func auth() async throws -> AuthInfo
    /// `POST /v1/admin/auth/qr`: request or refresh a QR login.
    func requestQRLogin() async throws -> AuthInfo
    /// `POST /v1/admin/auth/phone`.
    func submitPhoneNumber(_ phoneNumber: String) async throws -> AuthInfo
    /// `POST /v1/admin/auth/code`.
    func submitCode(_ code: String) async throws -> AuthInfo
    /// `POST /v1/admin/auth/password`.
    func submitPassword(_ password: String) async throws -> AuthInfo
    /// `POST /v1/admin/auth/email` (proposed; not in docs/api.md yet).
    func submitEmailAddress(_ email: String) async throws -> AuthInfo
    /// `POST /v1/admin/auth/email_code` (proposed; not in docs/api.md yet).
    func submitEmailCode(_ code: String) async throws -> AuthInfo
    /// `POST /v1/admin/auth/logout`.
    func logout() async throws

    // Chats
    /// `GET /v1/admin/chats?all=true`, following `next_cursor` until `has_more` is false.
    func allChats() async throws -> [Chat]
    /// `GET /v1/admin/folders`.
    func folders() async throws -> [Folder]
    /// `GET /v1/admin/monitored-chats`.
    func monitoredChats() async throws -> MonitoredChats
    /// `PUT /v1/admin/monitored-chats`: replaces the whole monitored set.
    func setMonitoredChats(chatIds: [String], folderIds: [String]) async throws -> MonitoredChats

    // Access requests and grants
    /// `GET /v1/admin/access-requests` (pending only).
    func accessRequests() async throws -> [AccessRequest]
    /// `POST /v1/admin/access-requests/{id}/approve`.
    func approve(requestId: String, selection: GrantChatSelection, scopes: [String]?) async throws -> Grant
    /// `POST /v1/admin/access-requests/{id}/deny`.
    func deny(requestId: String, reason: String?) async throws
    /// `GET /v1/admin/grants`.
    func grants() async throws -> [Grant]
    /// `GET /v1/admin/grants/{id}`.
    func grantDetail(id: String) async throws -> GrantDetail
    /// `DELETE /v1/admin/grants/{id}`.
    func revoke(grantId: String) async throws
    /// `POST /v1/admin/grants/{id}/webhook/resume`.
    func resumeWebhook(grantId: String) async throws
    /// `GET /v1/admin/grants/{id}/deliveries?limit=`.
    func deliveries(grantId: String, limit: Int) async throws -> [Delivery]
}
