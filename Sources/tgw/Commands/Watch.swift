import ArgumentParser
import Foundation
import TDLibClient

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print new, edited and deleted messages for the given chats as they arrive.",
        discussion: """
            One line per event: time received, the message's own date (and the latency between
            them), chat id, message id, sender, kind, and the text (first 120 characters) or
            content type. Never marks anything as read and keeps the account offline.
            """
    )

    @OptionGroup var credentials: CredentialOptions

    @Argument(help: "Chat ids to watch (from `tgw chats`).")
    var chatIds: [Int64] = []

    @Flag(help: "Watch every chat instead of the ones listed.")
    var all = false

    func validate() throws {
        if chatIds.isEmpty, !all {
            throw ValidationError("give at least one chat id, or --all")
        }
    }

    func run() async throws {
        let creds = try credentials.resolve()
        let wanted = Set(chatIds)
        let all = all
        try await Session.run(credentials: creds, command: "watch") { session in
            try await session.resume()
            let client = session.client

            // TDLib only pushes updates for chats it knows about, so load the list first and
            // make sure each watched chat is loaded. getChat does not mark anything as read.
            try await ChatList.loadAll(client)
            if all {
                warn("watching all chats")
            } else {
                for id in wanted.sorted() {
                    do {
                        let chat = try await client.send("getChat", ["chat_id": id])
                        warn("watching \(id)  \(Describe.chatType(chat.object("type")))  \(chat.string("title") ?? "")")
                    } catch let error as TDLibError {
                        warn("chat \(id): \(error.message) (still watching in case it appears)")
                    }
                }
            }

            for await update in client.updates {
                let now = Date()
                for (chatId, line) in Describe.messageLines(update: update, receivedAt: now)
                where all || wanted.contains(chatId) {
                    print(line)
                    fflush(stdout)
                }
            }
        }
    }
}
