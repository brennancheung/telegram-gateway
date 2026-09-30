import Foundation

/// One TDLib client. Owns request/response correlation (through the `@extra` field TDLib
/// echoes back), the stream of unsolicited updates, and the typed authorization state.
///
/// Lifecycle: `init` → `send(parameters.request)` when `waitTdlibParameters` arrives → drive
/// the auth states → work → `close()`. After `closed`, the instance is dead; make a new one.
public actor TDLibClient {
    public let clientId: Int32

    /// Every object TDLib sends that is not the response to a request: `updateNewMessage`,
    /// `updateAuthorizationState`, … Single consumer. Buffered without limit so a slow
    /// consumer never loses an update. Finishes when the client is closed.
    public nonisolated(unsafe) let updates: AsyncStream<JSONObject>

    /// Every authorization state change, in order, including the ones that happened before
    /// anyone started listening. Single consumer; `authState` / `waitForAuthState` are the
    /// re-entrant alternatives.
    public nonisolated let authStates: AsyncStream<AuthState>

    /// The latest authorization state, nil until TDLib has sent the first one.
    public private(set) var authState: AuthState?

    private let transport: any TDTransport
    private let updateContinuation: AsyncStream<JSONObject>.Continuation
    private let authContinuation: AsyncStream<AuthState>.Continuation
    private var pending: [String: CheckedContinuation<JSONBox, any Error>] = [:]
    private var authWaiters: [UUID: AuthWaiter] = [:]
    private var authVersion = 0
    private var nextExtra: UInt64 = 0
    private let extraPrefix: String
    private var isClosed = false

    private struct AuthWaiter {
        let predicate: @Sendable (AuthState) -> Bool
        let continuation: CheckedContinuation<AuthState, any Error>
    }

    /// Creates a real TDLib client. `td_execute setLogVerbosityLevel 1` runs once per process.
    public init() {
        let (clientId, inbox) = Receiver.shared.createClient()
        self.init(clientId: clientId, transport: LibraryTransport(), inbox: inbox)
    }

    init(clientId: Int32, transport: any TDTransport, inbox: AsyncStream<JSONBox>) {
        self.clientId = clientId
        self.transport = transport
        self.extraPrefix = "\(clientId)-\(UUID().uuidString.prefix(8))-"
        (updates, updateContinuation) = AsyncStream.makeStream(of: JSONObject.self, bufferingPolicy: .unbounded)
        (authStates, authContinuation) = AsyncStream.makeStream(of: AuthState.self, bufferingPolicy: .unbounded)
        // Consumes the inbox in order and ends when the inbox is finished (client closed).
        Task { [weak self] in
            for await box in inbox {
                guard let self else { return }
                await self.handle(box)
            }
            await self?.finish()
        }
    }

    // MARK: Requests

    /// Sends a request and returns its response. `request` must contain `@type`; an `@extra`
    /// is added for correlation (any caller-provided one is replaced). Throws `TDLibError`
    /// when TDLib answers with an `error` object, or `TDLibError.closed` if the client closes
    /// before answering.
    public func send(_ request: JSONObject) async throws -> sending JSONObject {
        if isClosed { throw TDLibError.closed }
        nextExtra += 1
        let extra = extraPrefix + String(nextExtra)
        var request = request
        request["@extra"] = extra
        let encoded = try encodeRequest(request)
        let box: JSONBox = try await withCheckedThrowingContinuation { continuation in
            pending[extra] = continuation
            transport.send(clientId: clientId, request: encoded)
        }
        return box.object
    }

    /// Convenience for the common shape: `send(["@type": type] + fields)`.
    public func send(_ type: String, _ fields: JSONObject = [:]) async throws -> sending JSONObject {
        var request = fields
        request["@type"] = type
        return try await send(request)
    }

    // MARK: Authorization

    /// Waits until the authorization state satisfies `predicate`. Returns at once if the
    /// current state already does. Throws `TDLibError.closed` if the client closes first
    /// (unless the predicate accepts `.closed`), and `CancellationError` on task cancellation.
    public func waitForAuthState(
        where predicate: @escaping @Sendable (AuthState) -> Bool
    ) async throws -> AuthState {
        if let authState, predicate(authState) { return authState }
        if isClosed { throw TDLibError.closed }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                authWaiters[id] = AuthWaiter(predicate: predicate, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelAuthWaiter(id) }
        }
    }

    /// Waits for the next authorization state after the one identified by `version` (as
    /// returned by a previous call), or returns the current one immediately if it is newer.
    /// This is how a login loop walks through states without missing one:
    /// ```
    /// var seen = 0
    /// while true {
    ///     let (state, version) = try await client.nextAuthState(after: seen)
    ///     seen = version
    ///     …
    /// }
    /// ```
    public func nextAuthState(after version: Int) async throws -> (state: AuthState, version: Int) {
        if let authState, authVersion > version { return (authState, authVersion) }
        if isClosed { throw TDLibError.closed }
        let id = UUID()
        let state = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                authWaiters[id] = AuthWaiter(predicate: { _ in true }, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelAuthWaiter(id) }
        }
        return (state, authVersion)
    }

    /// Sends `close` and waits for `closed`. Safe to call more than once. TDLib flushes its
    /// binlog on close; skipping this risks a slow recovery on next start.
    public func close() async {
        if isClosed { return }
        if authState == .closed { return }
        _ = try? await send("close")
        _ = try? await waitForAuthState { $0 == .closed }
    }

    // MARK: Routing

    private func handle(_ box: JSONBox) {
        let object = box.object
        if let extra = object["@extra"] as? String, let continuation = pending.removeValue(forKey: extra) {
            if object.type == "error" {
                continuation.resume(throwing: TDLibError(object: object))
            } else {
                continuation.resume(returning: box)
            }
            return
        }
        if object.type == "updateAuthorizationState", let stateObject = object.object("authorization_state") {
            let state = AuthState(object: stateObject)
            authState = state
            authVersion += 1
            authContinuation.yield(state)
            for (id, waiter) in authWaiters where waiter.predicate(state) {
                authWaiters.removeValue(forKey: id)
                waiter.continuation.resume(returning: state)
            }
        }
        let becameClosed = object.type == "updateAuthorizationState" && authState == .closed
        updateContinuation.yield(object)
        if becameClosed {
            finish()
        }
    }

    /// Called when `closed` arrives or the inbox ends: fail everything still waiting.
    private func finish() {
        if isClosed { return }
        isClosed = true
        if transport is LibraryTransport {
            Receiver.shared.remove(clientId: clientId)
        }
        for (_, continuation) in pending { continuation.resume(throwing: TDLibError.closed) }
        pending.removeAll()
        for (_, waiter) in authWaiters { waiter.continuation.resume(throwing: TDLibError.closed) }
        authWaiters.removeAll()
        updateContinuation.finish()
        authContinuation.finish()
    }

    private func cancelAuthWaiter(_ id: UUID) {
        if let waiter = authWaiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}
