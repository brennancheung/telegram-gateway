import ArgumentParser
import Foundation
import TDLibClient

struct Chats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the main chat list: id, type, unread count, title."
    )

    @OptionGroup var credentials: CredentialOptions

    @Option(help: "How many chats to print, most recent first.")
    var limit = 50

    func run() async throws {
        let creds = try credentials.resolve()
        let limit = limit
        try await Session.run(credentials: creds, command: "chats") { session in
            try await session.resume()
            let client = session.client
            try await ChatList.loadAll(client)
            let chatIds = try await ChatList.mainList(client, limit: limit)
            print(String(format: "%-16@ %-11@ %6@  %@", "id", "type", "unread", "title"))
            for id in chatIds {
                let chat = try await client.send("getChat", ["chat_id": id])
                let type = Describe.chatType(chat.object("type"))
                let unread = chat.int("unread_count") ?? 0
                let title = chat.string("title") ?? ""
                print(String(format: "%-16lld %-11@ %6d  %@", id, type, unread, title))
            }
        }
    }
}

/// Helpers for TDLib's chat list. TDLib only knows chats it has loaded; `loadChats` pulls the
/// main list from the server page by page until TDLib answers 404 ("nothing more to load").
enum ChatList {
    static func loadAll(_ client: TDLibClient) async throws {
        while true {
            do {
                _ = try await client.send("loadChats", ["chat_list": ["@type": "chatListMain"], "limit": 100])
            } catch let error as TDLibError where error.code == 404 {
                return
            }
        }
    }

    /// Chat ids of the main list in display order (most recent first).
    static func mainList(_ client: TDLibClient, limit: Int) async throws -> [Int64] {
        let response = try await client.send("getChats", ["chat_list": ["@type": "chatListMain"], "limit": limit])
        return (response.array("chat_ids") ?? []).compactMap { any in
            switch any {
            case let n as Int: Int64(n)
            case let n as NSNumber: n.int64Value
            default: nil
            }
        }
    }
}
