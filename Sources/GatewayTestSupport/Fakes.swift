import Foundation
import GatewayCore
import TDLibClient

/// Records webhook POSTs and answers with scripted statuses (or errors).
public actor FakeWebhookClient: WebhookHTTPClient {
    public struct Request: Sendable {
        public var url: URL
        public var headers: [(String, String)]
        public var body: Data
        public var timeout: Duration

        public func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    public enum Reply: Sendable {
        case status(Int)
        case failure(String)
    }

    public private(set) var requests: [Request] = []
    private var replies: [Reply] = []
    private var defaultReply: Reply = .status(200)
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Queues replies in order; when exhausted, `defaultReply` answers.
    public func enqueue(_ reply: Reply) {
        replies.append(reply)
    }

    public func setDefault(_ reply: Reply) {
        defaultReply = reply
    }

    public func post(url: URL, headers: [(String, String)], body: Data, timeout: Duration) async throws -> Int {
        requests.append(Request(url: url, headers: headers, body: body, timeout: timeout))
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
        let reply = replies.isEmpty ? defaultReply : replies.removeFirst()
        switch reply {
        case .status(let code): return code
        case .failure(let message): throw GatewayError.unavailable(message)
        }
    }

    /// Waits (real time, bounded) until at least `count` requests were made.
    public func waitForRequests(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while requests.count < count {
            if ContinuousClock.now > deadline {
                throw GatewayError.invalid("timed out waiting for \(count) webhook request(s); have \(requests.count)")
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    self.kick()
                }
            }
        }
    }

    private func kick() {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

/// A Telegram control whose state a test sets directly.
public actor FakeTelegram: TelegramControl {
    public var state: AuthState?
    public var connection: ConnectionState = .ready
    public var link: String?
    public var accountInfo: AccountInfo?
    public var tdlib: (any TDLibRequesting)?
    public private(set) var calls: [String] = []

    public init(state: AuthState? = .ready, tdlib: (any TDLibRequesting)? = nil) {
        self.state = state
        self.tdlib = tdlib
    }

    public func set(state: AuthState?) { self.state = state }
    public func set(connection: ConnectionState) { self.connection = connection }
    public func set(link: String?) { self.link = link }
    public func set(account: AccountInfo?) { accountInfo = account }

    public func authState() -> AuthState? { state }
    public func connectionState() -> ConnectionState { connection }
    public func qrLink() -> String? { link }
    public func account() -> AccountInfo? { accountInfo }
    public func requesting() -> (any TDLibRequesting)? { tdlib }

    public func requestQr() throws {
        calls.append("qr")
        link = "tg://login?token=FAKE"
        state = .waitOtherDeviceConfirmation(link: link ?? "")
    }

    public func setPhoneNumber(_ phone: String) throws {
        calls.append("phone:\(phone)")
        guard phone.hasPrefix("+") else { throw APIError.invalidRequest("phone_number", "PHONE_NUMBER_INVALID") }
        state = .waitCode
    }

    public func checkCode(_ code: String) throws {
        calls.append("code:\(code)")
        guard code == "12345" else { throw APIError.invalidRequest("code", "wrong_code") }
        state = .waitPassword(hint: "pet")
    }

    public func checkPassword(_ password: String) throws {
        calls.append("password")
        guard password == "hunter2" else {
            var error = APIError.invalidRequest("password", "wrong_password")
            error.details["password_hint"] = "pet"
            throw error
        }
        state = .ready
    }

    public func logOut() throws {
        calls.append("logout")
        state = .waitPhoneNumber
    }
}
