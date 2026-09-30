import Foundation
import TDLibClient

/// Turns TDLib objects into the one-line forms the commands print.
enum Describe {
    static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let isoSeconds = Date.ISO8601FormatStyle()

    /// `user` object → "First Last (@name) id=… phone=…".
    static func user(_ user: JSONObject) -> String {
        var parts: [String] = []
        let name = [user.string("first_name"), user.string("last_name")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        parts.append(name.isEmpty ? "(no name)" : name)
        if let usernames = user.object("usernames"),
           let active = usernames.array("active_usernames") as? [String],
           let first = active.first {
            parts.append("(@\(first))")
        }
        if let id = user.int64("id") { parts.append("id=\(id)") }
        if let phone = user.string("phone_number"), !phone.isEmpty { parts.append("phone=+\(phone)") }
        return parts.joined(separator: " ")
    }

    /// `ChatType` object → private / basicGroup / supergroup / channel / secret.
    static func chatType(_ type: JSONObject?) -> String {
        switch type?.type {
        case "chatTypePrivate": return "private"
        case "chatTypeBasicGroup": return "basicGroup"
        case "chatTypeSupergroup": return type?.bool("is_channel") == true ? "channel" : "supergroup"
        case "chatTypeSecret": return "secret"
        case let other: return other ?? "?"
        }
    }

    /// `MessageSender` object → "user:123" or "chat:-100…".
    static func sender(_ sender: JSONObject?) -> String {
        switch sender?.type {
        case "messageSenderUser": return "user:\(sender?.int64("user_id") ?? 0)"
        case "messageSenderChat": return "chat:\(sender?.int64("chat_id") ?? 0)"
        default: return "-"
        }
    }

    /// The text of a `MessageContent` (message text or media caption), trimmed to one line
    /// of at most `limit` characters, or nil when the content has no text.
    static func text(of content: JSONObject?, limit: Int = 120) -> String? {
        guard let content else { return nil }
        let raw = content.object("text")?.string("text") ?? content.object("caption")?.string("text")
        guard let raw, !raw.isEmpty else { return nil }
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }

    /// Content type without the `message` prefix: `messageText` → `text`, `messagePhoto` → `photo`.
    static func contentKind(_ content: JSONObject?) -> String {
        guard let type = content?.type else { return "?" }
        let stripped = type.hasPrefix("message") ? String(type.dropFirst("message".count)) : type
        return stripped.prefix(1).lowercased() + stripped.dropFirst()
    }

    /// Latency from the message's own timestamp to now, e.g. "+1.2s".
    static func latency(from unixSeconds: Int, to now: Date) -> String {
        let delta = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
        return String(format: "%+.1fs", delta)
    }

    /// One line for a message-related update, or nil if the update is not one of
    /// `updateNewMessage`, `updateMessageContent`, `updateDeleteMessages`.
    /// Columns: received-at, message date (+latency), chat, message, sender, kind, content.
    static func messageLines(update: JSONObject, receivedAt now: Date) -> [(chatId: Int64, line: String)] {
        let received = now.formatted(iso)
        switch update.type {
        case "updateNewMessage":
            guard let message = update.object("message"), let chatId = message.int64("chat_id") else { return [] }
            let date = message.int("date") ?? 0
            let content = message.object("content")
            let body = text(of: content).map { "\"\($0)\"" } ?? "(\(contentKind(content)))"
            let line = [
                received,
                "date=\(Date(timeIntervalSince1970: TimeInterval(date)).formatted(isoSeconds)) (\(latency(from: date, to: now)))",
                "chat=\(chatId)",
                "msg=\(message.int64("id") ?? 0)",
                "from=\(sender(message.object("sender_id")))",
                "new",
                contentKind(content),
                body,
            ].joined(separator: "  ")
            return [(chatId, line)]
        case "updateMessageContent":
            guard let chatId = update.int64("chat_id") else { return [] }
            let content = update.object("new_content")
            let body = text(of: content).map { "\"\($0)\"" } ?? "(\(contentKind(content)))"
            let line = [
                received, "date=-", "chat=\(chatId)", "msg=\(update.int64("message_id") ?? 0)", "from=-",
                "edited", contentKind(content), body,
            ].joined(separator: "  ")
            return [(chatId, line)]
        case "updateDeleteMessages":
            guard let chatId = update.int64("chat_id"), let ids = update.array("message_ids") else { return [] }
            let kind = update.bool("from_cache") == true ? "deleted-from-cache" : "deleted"
            let permanent = update.bool("is_permanent") == true ? "permanent" : "not-permanent"
            return ids.compactMap { any -> (Int64, String)? in
                let id: Int64?
                switch any {
                case let n as Int: id = Int64(n)
                case let n as NSNumber: id = n.int64Value
                case let s as String: id = Int64(s)
                default: id = nil
                }
                guard let id else { return nil }
                let line = [received, "date=-", "chat=\(chatId)", "msg=\(id)", "from=-", kind, permanent]
                    .joined(separator: "  ")
                return (chatId, line)
            }
        default:
            return []
        }
    }
}
