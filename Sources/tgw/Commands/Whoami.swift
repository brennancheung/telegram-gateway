import ArgumentParser
import Foundation
import TDLibClient

struct Whoami: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resume the existing login and print which account it is."
    )

    @OptionGroup var credentials: CredentialOptions

    func run() async throws {
        let creds = try credentials.resolve()
        try await Session.run(credentials: creds) { session in
            try await session.resume()
            let me = try await session.client.send("getMe")
            print(Describe.user(me))
        }
    }
}
