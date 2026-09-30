import ArgumentParser
import Foundation

/// The gateway version reported to Telegram as `application_version`.
let applicationVersion = "0.1.0"

@main
struct TGW: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tgw",
        abstract: "Telegram Gateway command-line tool.",
        discussion: """
            Logs in to the owner's own Telegram account through TDLib and lets you inspect \
            what the gateway sees. Data lives in ~/Library/Application Support/TelegramGateway/. \
            Never run two tgw commands (or tgw and the daemon) at the same time: TDLib's \
            directory can only be opened by one process.
            """,
        subcommands: [Login.self, Whoami.self, Chats.self, Watch.self, Logout.self]
    )
}

/// An error whose message is meant for the person at the terminal.
struct CLIError: Error, CustomStringConvertible, LocalizedError {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? { description }
}

/// Writes to stderr without buffering surprises.
func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
