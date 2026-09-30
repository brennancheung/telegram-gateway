import ArgumentParser
import Foundation
import TDLibClient

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Log out of Telegram. TDLib then deletes its local database."
    )

    @OptionGroup var credentials: CredentialOptions

    func run() async throws {
        let creds = try credentials.resolve()
        try await Session.run(credentials: creds, command: "logout") { session in
            let client = session.client
            // Parameters must be set before TDLib accepts logOut, whatever the login state.
            var seen = 0
            parameters: while true {
                let (state, version) = try await client.nextAuthState(after: seen)
                seen = version
                switch state {
                case .waitTdlibParameters:
                    _ = try await client.send(session.parameters.request)
                case .closed:
                    throw CLIError("TDLib closed before logging out")
                default:
                    break parameters
                }
            }
            _ = try await client.send("logOut")
            _ = try await client.waitForAuthState { $0 == .closed }
            print("Logged out; local Telegram data removed from \(session.paths.tdlib.path)")
        }
    }
}
