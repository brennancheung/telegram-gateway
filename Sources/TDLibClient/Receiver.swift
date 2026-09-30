import CTDLib
import Foundation
import Synchronization

/// How a `TDLibClient` talks to TDLib. The real one wraps `td_send`; tests substitute a fake
/// and push synthetic objects into the client's inbox.
protocol TDTransport: Sendable {
    func send(clientId: Int32, request: String)
}

struct LibraryTransport: TDTransport {
    func send(clientId: Int32, request: String) {
        td_send(clientId, request)
    }
}

/// The one receive loop for the process. `td_receive` is global: it returns objects for every
/// client, each tagged with `@client_id`, and only one thread may call it at a time. This runs
/// it on a dedicated thread (never a cooperative-pool task, because `td_receive` blocks) and
/// routes each decoded object to the inbox of the client it belongs to. Order per client is
/// preserved because delivery is a synchronous `yield` on the receive thread.
final class Receiver: Sendable {
    static let shared = Receiver()

    private struct State {
        var inboxes: [Int32: AsyncStream<JSONBox>.Continuation] = [:]
        var started = false
    }

    private let state = Mutex(State())

    private init() {
        // Errors only. Everything else is noise on a CLI and TDLib is chatty at 2+.
        _ = td_execute(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":1}"#)
    }

    /// Creates a TDLib client and the inbox that will receive its objects. Starts the receive
    /// thread on first use.
    func createClient() -> (clientId: Int32, inbox: AsyncStream<JSONBox>) {
        let clientId = td_create_client_id()
        let (inbox, continuation) = AsyncStream.makeStream(of: JSONBox.self)
        let needsStart = state.withLock { state in
            state.inboxes[clientId] = continuation
            let needsStart = !state.started
            state.started = true
            return needsStart
        }
        if needsStart {
            let thread = Thread { [self] in loop() }
            thread.name = "tdlib-receive"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        return (clientId, inbox)
    }

    /// Stops routing to a closed client and finishes its inbox.
    func remove(clientId: Int32) {
        let continuation = state.withLock { $0.inboxes.removeValue(forKey: clientId) }
        continuation?.finish()
    }

    private func loop() {
        while true {
            // The returned buffer is only valid until the next td_receive call: copy at once.
            guard let pointer = td_receive(1.0) else { continue }
            let data = Data(bytes: pointer, count: strlen(pointer))
            guard let envelope = Envelope.decode(data) else { continue }
            let inbox = state.withLock { $0.inboxes[envelope.clientId] }
            inbox?.yield(JSONBox(envelope.object))
        }
    }
}
