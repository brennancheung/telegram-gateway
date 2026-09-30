import Foundation

/// A small HTTP client for the daemon's API, used by `tgw` (and later the menu bar app).
/// Talks to `http://127.0.0.1:<port>` with a bearer token and returns parsed JSON.
public struct GatewayClient: Sendable {
    public struct Reply: Sendable {
        public var status: Int
        public var json: JSONValue
        public var requestId: String?

        public var isSuccess: Bool { (200..<300).contains(status) }
        public var errorCode: String? { json["error"]?["code"]?.stringValue }
        public var errorMessage: String? { json["error"]?["message"]?.stringValue }
    }

    public let baseURL: URL
    public let token: String?
    private let session: URLSession

    public init(port: Int, token: String?) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public func get(_ path: String) async throws -> Reply { try await send("GET", path, body: nil) }
    public func post(_ path: String, _ body: JSONValue? = nil) async throws -> Reply { try await send("POST", path, body: body) }
    public func put(_ path: String, _ body: JSONValue) async throws -> Reply { try await send("PUT", path, body: body) }
    public func delete(_ path: String) async throws -> Reply { try await send("DELETE", path, body: nil) }

    public func send(_ method: String, _ path: String, body: JSONValue?) async throws -> Reply {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw GatewayError.invalid("bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.serialized()
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GatewayError.unavailable("cannot reach the daemon at \(baseURL.absoluteString): \(error.localizedDescription). Is it running? (`tgw daemon status`)")
        }
        guard let http = response as? HTTPURLResponse else { throw GatewayError.unavailable("not an HTTP response") }
        let json = data.isEmpty ? JSONValue.null : ((try? JSONValue.parse(data)) ?? .null)
        return Reply(status: http.statusCode, json: json, requestId: http.value(forHTTPHeaderField: "X-TGW-Request-Id"))
    }

    /// A WebSocket to `path` with the bearer token, as URLSession provides it.
    public func webSocket(_ path: String) throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw GatewayError.invalid("bad base URL") }
        components.scheme = "ws"
        guard let base = components.url, let url = URL(string: path, relativeTo: base) else { throw GatewayError.invalid("bad path \(path)") }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return session.webSocketTask(with: request)
    }
}
