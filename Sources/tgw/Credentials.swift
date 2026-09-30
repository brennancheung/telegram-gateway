import ArgumentParser
import Foundation

/// The application's identity with Telegram: `api_id` (a number) and `api_hash` (a hex
/// string), obtained once at https://my.telegram.org under "API development tools". They
/// identify this software, not the account; the account is chosen at login.
struct Credentials: Sendable {
    let apiId: Int32
    let apiHash: String

    /// Resolution order: command-line flags, then `TGW_API_ID` / `TGW_API_HASH` in the
    /// environment, then `api_id` / `api_hash` in `Paths.config`.
    static func resolve(apiId: Int32?, apiHash: String?) throws -> Credentials {
        let env = ProcessInfo.processInfo.environment
        var id = apiId
        var hash = apiHash
        if id == nil, let s = env["TGW_API_ID"], let n = Int32(s) { id = n }
        if hash == nil, let s = env["TGW_API_HASH"], !s.isEmpty { hash = s }
        if id == nil || hash == nil, let file = readConfig() {
            if id == nil { id = file.apiId }
            if hash == nil { hash = file.apiHash }
        }
        guard let id, let hash, !hash.isEmpty else {
            throw CLIError(
                """
                Telegram API credentials are missing.

                Register an application at https://my.telegram.org (API development tools) to
                get an api_id and api_hash, then provide them one of these ways:
                  1. flags:        --api-id 12345 --api-hash 0123abcd…
                  2. environment:  TGW_API_ID=12345 TGW_API_HASH=0123abcd…
                  3. file:         \(Paths.config.path)
                                   {"api_id": 12345, "api_hash": "0123abcd…"}
                """)
        }
        return Credentials(apiId: id, apiHash: hash)
    }

    private static func readConfig() -> (apiId: Int32?, apiHash: String?)? {
        guard let data = try? Data(contentsOf: Paths.config),
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any]
        else { return nil }
        let id: Int32?
        switch object["api_id"] {
        case let n as Int: id = Int32(exactly: n)
        case let s as String: id = Int32(s)
        default: id = nil
        }
        return (id, object["api_hash"] as? String)
    }
}

/// `--api-id` / `--api-hash`, shared by every command.
struct CredentialOptions: ParsableArguments {
    @Option(name: .customLong("api-id"), help: "Telegram api_id (or TGW_API_ID, or config.json).")
    var apiId: Int32?

    @Option(name: .customLong("api-hash"), help: "Telegram api_hash (or TGW_API_HASH, or config.json).")
    var apiHash: String?

    func resolve() throws -> Credentials {
        try Credentials.resolve(apiId: apiId, apiHash: apiHash)
    }
}
