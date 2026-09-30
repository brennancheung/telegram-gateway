import Foundation
import GatewayCore
import Synchronization
import TDLibClient

/// One TDLib client plus the parameters for this machine. Every command opens one, does its
/// work, and closes it — also on Ctrl-C — so TDLib's binlog is left consistent. While open
/// it holds the instance lock, so it refuses to start while the daemon owns TDLib.
struct Session: Sendable {
    let client: TDLibClient
    let parameters: TDLibParameters
    let paths: Paths
    let lock: InstanceLock

    /// Creates the client and nudges TDLib so the first authorization state arrives
    /// (TDLib does nothing for a client until it receives a request).
    static func open(credentials: Credentials, command: String) async throws -> Session {
        let paths = Paths.resolve()
        try paths.prepare()
        let lock: InstanceLock
        do {
            lock = try InstanceLock.acquire(paths: paths, role: "tgw \(command)")
        } catch let error as GatewayError {
            throw CLIError(error.description)
        }
        let key = try Keychain.databaseKey()
        let parameters = TDLibParameters(
            apiId: credentials.apiId,
            apiHash: credentials.apiHash,
            databaseDirectory: paths.tdlib.path,
            filesDirectory: paths.tdlibFiles.path,
            databaseEncryptionKey: key,
            applicationVersion: applicationVersion
        )
        let client = TDLibClient()
        _ = try await client.send("getOption", ["name": "version"])
        return Session(client: client, parameters: parameters, paths: paths, lock: lock)
    }

    /// Answers `waitTdlibParameters`, then waits for `ready`. Fails with a clear message if
    /// the account is not logged in (`tgw login` is the fix). Once ready, tells TDLib the
    /// account is not online so the owner's status is never affected.
    func resume() async throws {
        var seen = 0
        while true {
            let (state, version) = try await client.nextAuthState(after: seen)
            seen = version
            switch state {
            case .waitTdlibParameters:
                _ = try await client.send(parameters.request)
            case .ready:
                try await goOffline()
                return
            case .loggingOut, .closing:
                continue
            case .closed:
                throw CLIError("TDLib closed before it became ready")
            case .waitPhoneNumber, .waitOtherDeviceConfirmation, .waitCode, .waitPassword,
                 .waitEmailAddress, .waitEmailCode, .waitRegistration, .waitPremiumPurchase:
                throw CLIError("not logged in (TDLib is at \(state)); run `tgw login` first")
            case .unknown(let type):
                throw CLIError("unexpected authorization state \(type); run `tgw login`")
            }
        }
    }

    /// `setOption online=false`. The option name is TDLib's (td/telegram/OptionManager.cpp).
    func goOffline() async throws {
        _ = try await client.send("setOption", [
            "name": "online",
            "value": ["@type": "optionValueBoolean", "value": false],
        ])
    }

    /// Sends `close` and waits for `closed`, giving up after a few seconds so a wedged TDLib
    /// cannot keep the process alive.
    func close() async {
        let closing = Task { await client.close() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(8))
            warn("TDLib did not close within 8s; exiting anyway")
            closing.cancel()
        }
        await closing.value
        watchdog.cancel()
    }

    /// Runs `body` with a session, then closes it whether `body` returned, threw, or was
    /// interrupted. The first Ctrl-C cancels `body` (its awaits throw `CancellationError`)
    /// and lets the close happen; a second Ctrl-C exits at once.
    static func run(
        credentials: Credentials,
        command: String,
        _ body: @escaping @Sendable (Session) async throws -> Void
    ) async throws {
        let session = try await open(credentials: credentials, command: command)
        let work = Task { try await body(session) }
        Interrupt.install {
            warn("\ninterrupted; closing TDLib (Ctrl-C again to force quit)")
            work.cancel()
        }
        let result = await work.result
        await session.close()
        withExtendedLifetime(session.lock) {}
        if case .failure(let error) = result, !(error is CancellationError) {
            throw error
        }
    }
}

/// SIGINT handling. The source must stay referenced for the life of the process.
enum Interrupt {
    private static let count = Mutex(0)
    private nonisolated(unsafe) static var source: DispatchSourceSignal?

    static func install(onFirst: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            let n = count.withLock { count in
                count += 1
                return count
            }
            if n == 1 {
                onFirst()
            } else {
                exit(130)
            }
        }
        source.resume()
        Interrupt.source = source
    }
}
