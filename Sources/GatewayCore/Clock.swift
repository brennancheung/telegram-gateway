import Foundation
import Synchronization

/// Time as the gateway sees it. Production uses `SystemClock`; tests use `ManualClock` to
/// drive expiries and the webhook retry ladder without waiting.
public protocol GatewayClock: Sendable {
    var now: Date { get }
    /// Suspends until `duration` has passed on this clock. Throws `CancellationError` when the
    /// task is cancelled.
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: GatewayClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// A clock that only moves when `advance` is called. Sleepers wake in deadline order when
/// the clock passes their deadline.
public final class ManualClock: GatewayClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
        var nextId: UInt64 = 0
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date { state.withLock { $0.now } }

    /// Number of tasks currently sleeping. Tests use it to know a loop has parked.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let id = state.withLock { state in
            state.nextId += 1
            return state.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let fireNow: Bool = state.withLock { state in
                    let deadline = state.now.addingTimeInterval(seconds)
                    if deadline <= state.now { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if fireNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and wakes every sleeper whose deadline has passed, in order.
    public func advance(by duration: Duration) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        advance(to: now.addingTimeInterval(seconds))
    }

    public func advance(to date: Date) {
        let due: [Sleeper] = state.withLock { state in
            state.now = max(state.now, date)
            let due = state.sleepers.filter { $0.deadline <= state.now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits (in real time, briefly) until `count` tasks are parked in `sleep`. Lets a test
    /// advance the clock only once the code under test has actually started waiting.
    public func waitForSleepers(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while sleeperCount < count {
            if ContinuousClock.now > deadline {
                throw GatewayError.invalid("timed out waiting for \(count) sleeper(s); have \(sleeperCount)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
