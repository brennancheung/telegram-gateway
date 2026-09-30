import Foundation
import Synchronization
import Testing

@testable import TDLibClient

/// Records what the client sends and lets a test hand back synthetic responses, standing in
/// for td_send / td_receive.
final class FakeTransport: TDTransport {
    let requests: AsyncStream<JSONBox>
    private let continuation: AsyncStream<JSONBox>.Continuation

    init() {
        (requests, continuation) = AsyncStream.makeStream(of: JSONBox.self, bufferingPolicy: .unbounded)
    }

    func send(clientId: Int32, request: String) {
        let any = try? JSONSerialization.jsonObject(with: Data(request.utf8))
        if let object = any as? JSONObject {
            continuation.yield(JSONBox(object))
        }
    }
}

/// A client wired to a fake transport plus the inbox continuation the test pushes into.
struct Harness {
    let client: TDLibClient
    let transport: FakeTransport
    let inbox: AsyncStream<JSONBox>.Continuation
    var requests: AsyncStream<JSONBox>.Iterator

    init() {
        let transport = FakeTransport()
        let (stream, continuation) = AsyncStream.makeStream(of: JSONBox.self, bufferingPolicy: .unbounded)
        client = TDLibClient(clientId: 7, transport: transport, inbox: stream)
        self.transport = transport
        inbox = continuation
        requests = transport.requests.makeAsyncIterator()
    }

    /// The next request the client sent.
    mutating func nextRequest() async throws -> JSONObject {
        try #require(await requests.next()).object
    }

    func receive(_ object: JSONObject) {
        inbox.yield(JSONBox(object))
    }

    func receiveAuthState(_ type: String, _ fields: JSONObject = [:]) {
        var state = fields
        state["@type"] = type
        receive(["@type": "updateAuthorizationState", "@client_id": 7, "authorization_state": state])
    }
}

@Suite struct CorrelationTests {
    @Test func responseIsMatchedByExtra() async throws {
        var h = Harness()
        let client = h.client
        let response = Task { JSONBox(try await client.send("getMe")) }
        let request = try await h.nextRequest()
        let extra = try #require(request.string("@extra"))
        #expect(request.type == "getMe")
        h.receive(["@type": "user", "@client_id": 7, "@extra": extra, "id": 42])
        let user = try await response.value.object
        #expect(user.int("id") == 42)
    }

    @Test func outOfOrderResponsesReachTheRightCaller() async throws {
        var h = Harness()
        let client = h.client
        let first = Task { JSONBox(try await client.send("getChat", ["chat_id": 1])) }
        let second = Task { JSONBox(try await client.send("getChat", ["chat_id": 2])) }
        let requestA = try await h.nextRequest()
        let requestB = try await h.nextRequest()
        let extraA = try #require(requestA.string("@extra"))
        let extraB = try #require(requestB.string("@extra"))
        #expect(extraA != extraB)
        // Answer in reverse order.
        h.receive(["@type": "chat", "@client_id": 7, "@extra": extraB, "id": requestB.int("chat_id") ?? -1])
        h.receive(["@type": "chat", "@client_id": 7, "@extra": extraA, "id": requestA.int("chat_id") ?? -1])
        let chatA = try await first.value.object
        let chatB = try await second.value.object
        // Whichever request went out first, each caller got the chat it asked for.
        #expect(chatA.int("id") == 1)
        #expect(chatB.int("id") == 2)
    }

    @Test func errorObjectsThrowTypedError() async throws {
        var h = Harness()
        let client = h.client
        let response = Task { JSONBox(try await client.send("loadChats")) }
        let extra = try #require(try await h.nextRequest().string("@extra"))
        h.receive(["@type": "error", "@client_id": 7, "@extra": extra, "code": 404, "message": "Not Found"])
        await #expect(throws: TDLibError(code: 404, message: "Not Found")) {
            try await response.value
        }
    }

    @Test func callerProvidedExtraIsReplaced() async throws {
        var h = Harness()
        let client = h.client
        let response = Task { JSONBox(try await client.send(["@type": "getMe", "@extra": "mine"])) }
        let request = try await h.nextRequest()
        let extra = try #require(request.string("@extra"))
        #expect(extra != "mine")
        h.receive(["@type": "user", "@client_id": 7, "@extra": extra])
        _ = try await response.value
    }

    @Test func updatesWithoutExtraGoToTheUpdateStream() async throws {
        let h = Harness()
        h.receive(["@type": "updateNewMessage", "@client_id": 7, "message": ["id": 5]])
        var iterator = h.client.updates.makeAsyncIterator()
        let update = try #require(await iterator.next())
        #expect(update.type == "updateNewMessage")
        #expect(update.object("message")?.int("id") == 5)
    }

    @Test func unmatchedExtraIsTreatedAsAnUpdate() async throws {
        // A response whose @extra nobody is waiting for (e.g. from a previous process) must
        // not be dropped silently or crash; it flows to the update stream.
        let h = Harness()
        h.receive(["@type": "ok", "@client_id": 7, "@extra": "stale"])
        var iterator = h.client.updates.makeAsyncIterator()
        let object = try #require(await iterator.next())
        #expect(object.type == "ok")
    }

    @Test func authStateIsDecodedAndStreamed() async throws {
        let h = Harness()
        h.receiveAuthState("authorizationStateWaitTdlibParameters")
        h.receiveAuthState("authorizationStateWaitOtherDeviceConfirmation", ["link": "tg://login?token=x"])
        var iterator = h.client.authStates.makeAsyncIterator()
        #expect(await iterator.next() == .waitTdlibParameters)
        #expect(await iterator.next() == .waitOtherDeviceConfirmation(link: "tg://login?token=x"))
        #expect(await h.client.authState == .waitOtherDeviceConfirmation(link: "tg://login?token=x"))
    }

    @Test func nextAuthStateWalksEveryState() async throws {
        let h = Harness()
        let client = h.client
        h.receiveAuthState("authorizationStateWaitTdlibParameters")
        let (first, v1) = try await client.nextAuthState(after: 0)
        #expect(first == .waitTdlibParameters)
        // Nothing newer yet: this waits until the next state arrives.
        let waiting = Task { try await client.nextAuthState(after: v1) }
        h.receiveAuthState("authorizationStateWaitPhoneNumber")
        let (second, v2) = try await waiting.value
        #expect(second == .waitPhoneNumber)
        #expect(v2 > v1)
        // Already newer than the version asked for: returns at once.
        let (again, v3) = try await client.nextAuthState(after: v1)
        #expect(again == .waitPhoneNumber)
        #expect(v3 == v2)
    }

    @Test func waitForAuthStateResolvesOnMatch() async throws {
        let h = Harness()
        let client = h.client
        let ready = Task { try await client.waitForAuthState { $0 == .ready } }
        h.receiveAuthState("authorizationStateWaitPhoneNumber")
        h.receiveAuthState("authorizationStateReady")
        #expect(try await ready.value == .ready)
        // Current state already matches: no waiting.
        #expect(try await client.waitForAuthState { $0 == .ready } == .ready)
    }

    @Test func closedFailsPendingRequestsAndFinishesStreams() async throws {
        var h = Harness()
        let client = h.client
        let pending = Task { JSONBox(try await client.send("getMe")) }
        _ = try await h.nextRequest()
        let waiter = Task { try await client.waitForAuthState { $0 == .ready } }
        h.receiveAuthState("authorizationStateClosing")
        h.receiveAuthState("authorizationStateClosed")

        await #expect(throws: TDLibError.closed) { try await pending.value }
        await #expect(throws: TDLibError.closed) { try await waiter.value }
        await #expect(throws: TDLibError.closed) { try await client.send("getMe") }

        var auth = client.authStates.makeAsyncIterator()
        #expect(await auth.next() == .closing)
        #expect(await auth.next() == .closed)
        #expect(await auth.next() == nil, "stream finishes after closed")
    }

    @Test func closeSendsCloseAndWaitsForClosed() async throws {
        var h = Harness()
        let client = h.client
        let closing = Task { await client.close() }
        let request = try await h.nextRequest()
        #expect(request.type == "close")
        h.receive(["@type": "ok", "@client_id": 7, "@extra": request.string("@extra") ?? ""])
        h.receiveAuthState("authorizationStateClosed")
        await closing.value
        #expect(await client.authState == .closed)
    }

    @Test func cancelledWaiterDoesNotLeak() async throws {
        let h = Harness()
        let client = h.client
        let waiter = Task { try await client.waitForAuthState { $0 == .ready } }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        // A later state change must not try to resume the cancelled continuation.
        h.receiveAuthState("authorizationStateReady")
        #expect(try await client.waitForAuthState { $0 == .ready } == .ready)
    }
}
