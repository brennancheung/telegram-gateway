import ArgumentParser
import Foundation
import GatewayCore

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Read the event log.",
        subcommands: [Tail.self, Page.self],
        defaultSubcommand: Tail.self
    )

    static func line(_ event: JSONValue) -> String {
        let seq = event["seq"]?.intValue ?? 0
        let type = event["type"]?.stringValue ?? "?"
        let chat = event["chat"]
        let title = chat?["title"]?.stringValue ?? ""
        let chatId = chat?["id"]?.stringValue ?? ""
        var detail = ""
        switch type {
        case "message.new", "message.edited":
            let m = event["message"]
            let sender = m?["sender"]?["display_name"]?.stringValue ?? ""
            let text = (m?["text"]?.stringValue ?? "").replacingOccurrences(of: "\n", with: " ")
            let media = (m?["media"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }.joined(separator: ",")
            detail = "msg=\(m?["id"]?.stringValue ?? "") from=\(sender)\(media.isEmpty ? "" : " [\(media)]") \(text.prefix(120))"
        case "message.deleted":
            detail = "ids=\(Admin.idList(event["message_ids"]))"
        case "chat.updated":
            detail = "changes=\((event["changes"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ","))"
        case "monitoring.started", "monitoring.stopped":
            detail = "source=\(event["monitoring"]?["source"]?.stringValue ?? "")"
        default:
            break
        }
        return "\(seq)  \(Admin.short(event["occurred_at"]))  \(type)  \(chatId) \"\(title)\"  \(detail)"
    }

    struct Tail: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Follow the event stream over the WebSocket (Ctrl-C to stop).")

        @Option(help: "Replay from this sequence number (exclusive) before going live; omit for live only.")
        var since: Int64?

        @Option(help: "Comma-separated event types to include.")
        var types: String?

        @Option(name: .customLong("chat"), parsing: .upToNextOption, help: "Only these chat ids.")
        var chats: [String] = []

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = try Admin.client()
            var query: [String] = []
            if let since { query.append("since=\(since)") }
            if let types { query.append("types=\(types)") }
            for chat in chats { query.append("chat_id=\(chat)") }
            let path = "/v1/events/stream" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
            let task = try client.webSocket(path)
            task.resume()
            while true {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                let frame = try JSONValue.parse(text)
                if output.json { print(text); fflush(stdout); continue }
                switch frame["type"]?.stringValue {
                case "event": if let event = frame["event"] { print(EventsCommand.line(event)) }
                case "caught_up": warn("caught up at seq \(frame["seq"]?.intValue ?? 0); live")
                case "heartbeat": break
                case "error": throw CLIError("\(frame["code"]?.stringValue ?? "error"): \(frame["message"]?.stringValue ?? "")")
                default: break
                }
                fflush(stdout)
            }
        }
    }

    struct Page: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One page of the log (GET /v1/events).")

        @Option(help: "Exclusive lower bound on seq.")
        var since: Int64 = 0

        @Option(help: "Page size (1–1000).")
        var limit = 100

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = try Admin.client()
            let json = try Admin.check(try await client.get("/v1/events?since=\(since)&limit=\(limit)"))
            if output.json { print(json.pretty()); return }
            for event in json["events"]?.arrayValue ?? [] { print(EventsCommand.line(event)) }
            print("has_more=\(json["has_more"]?.boolValue ?? false) next_since=\(json["next_since"]?.intValue ?? 0) head_seq=\(json["head_seq"]?.intValue ?? 0)")
        }
    }
}
