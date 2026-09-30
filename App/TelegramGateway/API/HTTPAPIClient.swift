import Foundation

/// The real client: JSON over HTTP to the daemon on `127.0.0.1:<port>` (docs/api.md). The
/// admin token is read through `token` on every request so a token that appears in the
/// secrets file after the app started is picked up without rebuilding the client.
final class HTTPAPIClient: APIClient {
    let baseURL: URL
    private let token: @Sendable () -> String?
    private let session: URLSession

    init(baseURL: URL, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Health and status

    func health() async throws -> Health {
        try await get("/v1/health", authenticated: false)
    }

    func adminStatus() async throws -> AdminStatus {
        try await get("/v1/admin/status")
    }

    // MARK: Login

    func auth() async throws -> AuthInfo {
        try await get("/v1/admin/auth")
    }

    func requestQRLogin() async throws -> AuthInfo {
        try await postThenAuth("/v1/admin/auth/qr", body: nil)
    }

    func submitPhoneNumber(_ phoneNumber: String) async throws -> AuthInfo {
        try await postThenAuth("/v1/admin/auth/phone", body: ["phone_number": phoneNumber])
    }

    func submitCode(_ code: String) async throws -> AuthInfo {
        try await postThenAuth("/v1/admin/auth/code", body: ["code": code])
    }

    func submitPassword(_ password: String) async throws -> AuthInfo {
        try await postThenAuth("/v1/admin/auth/password", body: ["password": password])
    }

    func submitEmailAddress(_ email: String) async throws -> AuthInfo {
        try await postThenAuth("/v1/admin/auth/email", body: ["email_address": email])
    }

    func submitEmailCode(_ code: String) async throws -> AuthInfo {
        try await postThenAuth("/v1/admin/auth/email_code", body: ["code": code])
    }

    func logout() async throws {
        _ = try await request("POST", "/v1/admin/auth/logout", body: nil)
    }

    // MARK: Chats

    func allChats() async throws -> [Chat] {
        var chats: [Chat] = []
        var cursor: String?
        // 200 per page; 50 pages is 10 000 chats, far beyond any real account.
        for _ in 0..<50 {
            var query = [URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: ChatPage = try await get("/v1/admin/chats", query: query)
            chats.append(contentsOf: page.chats)
            guard page.hasMore, let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        return chats
    }

    func folders() async throws -> [Folder] {
        let list: FolderList = try await get("/v1/admin/folders")
        return list.folders
    }

    func monitoredChats() async throws -> MonitoredChats {
        try await get("/v1/admin/monitored-chats")
    }

    func setMonitoredChats(chatIds: [String], folderIds: [String]) async throws -> MonitoredChats {
        let data = try APIJSON.encoder.encode(MonitoredChatsUpdate(chatIds: chatIds, folderIds: folderIds))
        return try await decode(try await request("PUT", "/v1/admin/monitored-chats", body: data))
    }

    // MARK: Access requests and grants

    func accessRequests() async throws -> [AccessRequest] {
        let list: AccessRequestList = try await get("/v1/admin/access-requests")
        return list.accessRequests
    }

    func approve(requestId: String, selection: GrantChatSelection, scopes: [String]?) async throws -> Grant {
        let data = try APIJSON.encoder.encode(ApproveRequest(selection: selection, scopes: scopes))
        return try await decode(try await request("POST", "/v1/admin/access-requests/\(requestId)/approve", body: data))
    }

    func deny(requestId: String, reason: String?) async throws {
        let data = try APIJSON.encoder.encode(DenyRequest(reason: reason))
        _ = try await request("POST", "/v1/admin/access-requests/\(requestId)/deny", body: data)
    }

    func grants() async throws -> [Grant] {
        let list: GrantList = try await get("/v1/admin/grants")
        return list.grants
    }

    func grantDetail(id: String) async throws -> GrantDetail {
        try await get("/v1/admin/grants/\(id)")
    }

    func revoke(grantId: String) async throws {
        _ = try await request("DELETE", "/v1/admin/grants/\(grantId)", body: nil)
    }

    func resumeWebhook(grantId: String) async throws {
        _ = try await request("POST", "/v1/admin/grants/\(grantId)/webhook/resume", body: nil)
    }

    func deliveries(grantId: String, limit: Int) async throws -> [Delivery] {
        let list: DeliveryList = try await get("/v1/admin/grants/\(grantId)/deliveries", query: [URLQueryItem(name: "limit", value: String(limit))])
        return list.deliveries
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = true) async throws -> T {
        try await decode(try await request("GET", path, query: query, body: nil, authenticated: authenticated))
    }

    /// The login POSTs' response bodies are not specified in docs/api.md. If the body decodes
    /// as an `AuthInfo` it is used; otherwise the state is re-read with `GET /v1/admin/auth`.
    private func postThenAuth(_ path: String, body: [String: String]?) async throws -> AuthInfo {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let response = try await request("POST", path, body: data)
        if let info = try? APIJSON.decoder.decode(AuthInfo.self, from: response) {
            return info
        }
        return try await auth()
    }

    private func decode<T: Decodable>(_ data: Data) async throws -> T {
        do {
            return try APIJSON.decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding(String(describing: error))
        }
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data?, authenticated: Bool = true) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let token = token() else { throw APIClientError.noToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIClientError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIClientError.unexpectedStatus(0) }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? APIJSON.decoder.decode(APIError.Envelope.self, from: data) {
                let hint = envelope.passwordHint ?? envelope.error.details?["password_hint"]?.stringValue
                throw APIClientError.api(envelope.error, status: http.statusCode, passwordHint: hint)
            }
            throw APIClientError.unexpectedStatus(http.statusCode)
        }
        return data
    }
}
