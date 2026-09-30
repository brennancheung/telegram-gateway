import Foundation
import TDLibClient

/// A translated message plus the media index entries it references.
public struct TranslatedMessage: Sendable, Equatable {
    public var chat: ChatInfo
    public var message: Message
    public var media: [MediaRecord]

    public init(chat: ChatInfo, message: Message, media: [MediaRecord]) {
        self.chat = chat
        self.message = message
        self.media = media
    }
}

/// What one TDLib update means to the gateway. The monitor turns these into log entries.
public enum Translated: Sendable, Equatable {
    /// A message arrived (or finished sending, for the user's own).
    case messageNew(TranslatedMessage)
    /// A message's content changed; `editDate` is the dedupe key with `updateMessageContent`.
    case messageEdited(TranslatedMessage)
    /// Messages deleted for everyone. Public message ids.
    case messageDeleted(chatId: Int64, messageIds: [Int64])
    /// Something about a chat changed (title, photo, username, member count). The monitor
    /// re-reads the chat if it is monitored.
    case chatChanged(chatId: Int64)
    /// The account's chat folders changed. Carries the folder ids and titles.
    case foldersChanged([(id: Int64, title: String)])
    /// A chat entered or left a folder.
    case folderMembership(folderId: Int64, chatId: Int64, added: Bool)
    case connectionState(ConnectionState)

    public static func == (lhs: Translated, rhs: Translated) -> Bool {
        switch (lhs, rhs) {
        case (.messageNew(let a), .messageNew(let b)): a == b
        case (.messageEdited(let a), .messageEdited(let b)): a == b
        case (.messageDeleted(let c1, let m1), .messageDeleted(let c2, let m2)): c1 == c2 && m1 == m2
        case (.chatChanged(let a), .chatChanged(let b)): a == b
        case (.foldersChanged(let a), .foldersChanged(let b)): a.map(\.id) == b.map(\.id) && a.map(\.title) == b.map(\.title)
        case (.folderMembership(let f1, let c1, let a1), .folderMembership(let f2, let c2, let a2)): f1 == f2 && c1 == c2 && a1 == a2
        case (.connectionState(let a), .connectionState(let b)): a == b
        default: false
        }
    }
}

/// TDLib JSON → the objects in docs/events.md. This is the boundary: nothing `Any`-typed
/// leaves it. Sender and chat details come from TDLib's local cache through `getUser`,
/// `getChat`, `getSupergroup`, `getBasicGroup`, memoised here; the field names follow
/// vendor/tdlib/src/td/generate/scheme/td_api.tl at the pinned commit.
public actor Translator {
    private let tdlib: any TDLibRequesting
    private var chatCache: [Int64: ChatInfo] = [:]
    private var userCache: [Int64: Sender] = [:]
    /// (chat id, message id, edit date) already emitted as `message.edited`, most recent last.
    private var recentEdits: [EditKey] = []

    private struct EditKey: Equatable {
        let chatId: Int64
        let messageId: Int64
        let editDate: Int
    }

    public init(tdlib: any TDLibRequesting) {
        self.tdlib = tdlib
    }

    // MARK: Updates

    /// Translates one update. Returns an empty array for updates the gateway does not model.
    public func translate(update box: JSONBox) async throws -> [Translated] {
        let update = box.object
        switch update.type {
        case "updateNewMessage":
            guard let message = update.object("message") else { return [] }
            // A message the user is still sending has a local id; the final one arrives with
            // updateMessageSendSucceeded.
            if message.object("sending_state") != nil { return [] }
            return [.messageNew(try await translateMessage(message))]

        case "updateMessageSendSucceeded":
            guard let message = update.object("message") else { return [] }
            return [.messageNew(try await translateMessage(message))]

        case "updateMessageEdited":
            guard let chatId = update.int64("chat_id"), let messageId = update.int64("message_id") else { return [] }
            return try await edited(chatId: chatId, messageId: messageId, editDate: update.int("edit_date") ?? 0)

        case "updateMessageContent":
            guard let chatId = update.int64("chat_id"), let messageId = update.int64("message_id") else { return [] }
            return try await edited(chatId: chatId, messageId: messageId, editDate: nil)

        case "updateDeleteMessages":
            guard update.bool("is_permanent") == true, update.bool("from_cache") != true,
                  let chatId = update.int64("chat_id"), let ids = update.array("message_ids") else { return [] }
            let publicIds = ids.compactMap(Translator.int64).map(MessageId.toPublic)
            guard !publicIds.isEmpty else { return [] }
            return [.messageDeleted(chatId: chatId, messageIds: publicIds)]

        case "updateChatTitle", "updateChatPhoto":
            guard let chatId = update.int64("chat_id") else { return [] }
            chatCache.removeValue(forKey: chatId)
            return [.chatChanged(chatId: chatId)]

        case "updateSupergroup":
            guard let id = update.object("supergroup")?.int64("id") else { return [] }
            let chatId = ChatIdArithmetic.chatId(supergroupId: id)
            chatCache.removeValue(forKey: chatId)
            return [.chatChanged(chatId: chatId)]

        case "updateSupergroupFullInfo":
            guard let id = update.int64("supergroup_id") else { return [] }
            let chatId = ChatIdArithmetic.chatId(supergroupId: id)
            chatCache.removeValue(forKey: chatId)
            return [.chatChanged(chatId: chatId)]

        case "updateBasicGroup":
            guard let id = update.object("basic_group")?.int64("id") else { return [] }
            let chatId = ChatIdArithmetic.chatId(basicGroupId: id)
            chatCache.removeValue(forKey: chatId)
            return [.chatChanged(chatId: chatId)]

        case "updateBasicGroupFullInfo":
            guard let id = update.int64("basic_group_id") else { return [] }
            let chatId = ChatIdArithmetic.chatId(basicGroupId: id)
            chatCache.removeValue(forKey: chatId)
            return [.chatChanged(chatId: chatId)]

        case "updateUser":
            guard let id = update.object("user")?.int64("id") else { return [] }
            userCache.removeValue(forKey: id)
            chatCache.removeValue(forKey: id)
            return [.chatChanged(chatId: id)]

        case "updateChatFolders":
            let folders = (update.array("chat_folders") ?? []).compactMap { any -> (id: Int64, title: String)? in
                guard let info = any as? JSONObject, let id = info.int64("id") else { return nil }
                return (id, info.object("name")?.object("text")?.string("text") ?? "")
            }
            return [.foldersChanged(folders)]

        case "updateChatAddedToList", "updateChatRemovedFromList":
            guard let chatId = update.int64("chat_id"), let list = update.object("chat_list"),
                  list.type == "chatListFolder", let folderId = list.int64("chat_folder_id") else { return [] }
            return [.folderMembership(folderId: folderId, chatId: chatId, added: update.type == "updateChatAddedToList")]

        case "updateConnectionState":
            guard let state = update.object("state") else { return [] }
            return [.connectionState(ConnectionState(object: state))]

        default:
            return []
        }
    }

    /// Both edit updates converge here: fetch the message, emit once per (chat, id, edit_date).
    /// A content change on a never-edited message (a poll vote, a link preview loading) is
    /// not an edit and produces nothing.
    private func edited(chatId: Int64, messageId: Int64, editDate: Int?) async throws -> [Translated] {
        let message = try await tdlib.request("getMessage", ["chat_id": chatId, "message_id": messageId]).object
        let date = max(editDate ?? 0, message.int("edit_date") ?? 0)
        guard date > 0 else { return [] }
        let key = EditKey(chatId: chatId, messageId: messageId, editDate: date)
        if recentEdits.contains(key) { return [] }
        recentEdits.append(key)
        if recentEdits.count > 512 { recentEdits.removeFirst(recentEdits.count - 512) }
        var translated = try await translateMessage(message)
        translated.message.editDate = Date(timeIntervalSince1970: TimeInterval(date))
        return [.messageEdited(translated)]
    }

    // MARK: Messages

    /// A TDLib `message` object → the message object, with sender and chat resolved.
    public func translateMessage(_ box: JSONBox) async throws -> TranslatedMessage {
        try await translateMessage(box.object)
    }

    private func translateMessage(_ m: JSONObject) async throws -> TranslatedMessage {
        guard let internalId = m.int64("id"), let chatId = m.int64("chat_id") else {
            throw GatewayError.invalid("message without id/chat_id")
        }
        let chat = try await chatInfo(chatId)
        let sender = try await translateSender(m.object("sender_id"), fallbackChat: chat)
        let content = m.object("content") ?? [:]
        let (text, entities) = Translator.text(of: content)
        let (mediaList, records) = Translator.media(of: content)
        let publicId = MessageId.toPublic(internalId)
        var replyTo: ReplyTo?
        if let reply = m.object("reply_to"), reply.type == "messageReplyToMessage",
           let replyChat = reply.int64("chat_id"), let replyMessage = reply.int64("message_id"), replyMessage != 0 {
            replyTo = ReplyTo(chatId: replyChat, messageId: MessageId.toPublic(replyMessage))
        }
        var forward: ForwardOrigin?
        if let info = m.object("forward_info"), let origin = info.object("origin") {
            forward = try await translateOrigin(origin, date: Date(timeIntervalSince1970: TimeInterval(info.int("date") ?? 0)))
        }
        let albumId = m.int64("media_album_id").flatMap { $0 == 0 ? nil : String($0) }
        let editDate = (m.int("edit_date") ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(m.int("edit_date") ?? 0)) : nil
        let message = Message(
            id: publicId,
            chatId: chatId,
            sender: sender,
            date: Date(timeIntervalSince1970: TimeInterval(m.int("date") ?? 0)),
            editDate: editDate,
            isOutgoing: m.bool("is_outgoing") ?? false,
            text: text,
            entities: entities,
            replyTo: replyTo,
            forwardFrom: forward,
            media: mediaList,
            mediaGroupId: albumId,
            link: chat.username.map { "https://t.me/\($0)/\(publicId)" },
            rawContentType: content.type ?? "unknown"
        )
        return TranslatedMessage(chat: chat, message: message, media: records)
    }

    private func translateSender(_ sender: JSONObject?, fallbackChat: ChatInfo) async throws -> Sender {
        switch sender?.type {
        case "messageSenderUser":
            guard let userId = sender?.int64("user_id") else { break }
            return try await user(userId)
        case "messageSenderChat":
            guard let chatId = sender?.int64("chat_id") else { break }
            let chat = chatId == fallbackChat.id ? fallbackChat : try await chatInfo(chatId)
            return Sender(type: .chat, id: chat.id, displayName: chat.title, username: chat.username, isBot: nil)
        default:
            break
        }
        return Sender(type: .chat, id: fallbackChat.id, displayName: fallbackChat.title, username: fallbackChat.username, isBot: nil)
    }

    private func translateOrigin(_ origin: JSONObject, date: Date) async throws -> ForwardOrigin? {
        switch origin.type {
        case "messageOriginUser":
            guard let userId = origin.int64("sender_user_id") else { return nil }
            let user = try await user(userId)
            return ForwardOrigin(type: .user, id: user.id, displayName: user.displayName, username: user.username, messageId: nil, date: date)
        case "messageOriginHiddenUser":
            return ForwardOrigin(type: .hiddenUser, id: nil, displayName: origin.string("sender_name") ?? "", username: nil, messageId: nil, date: date)
        case "messageOriginChat":
            guard let chatId = origin.int64("sender_chat_id") else { return nil }
            let chat = try await chatInfo(chatId)
            return ForwardOrigin(type: .chat, id: chat.id, displayName: chat.title, username: chat.username, messageId: nil, date: date)
        case "messageOriginChannel":
            guard let chatId = origin.int64("chat_id") else { return nil }
            let chat = try await chatInfo(chatId)
            let messageId = origin.int64("message_id").map(MessageId.toPublic)
            return ForwardOrigin(type: .chat, id: chat.id, displayName: chat.title, username: chat.username, messageId: messageId, date: date)
        default:
            return nil
        }
    }

    /// Text or caption, plus the entity subset the format keeps, sorted by offset.
    static func text(of content: JSONObject) -> (String, [Entity]) {
        let formatted = content.object("text") ?? content.object("caption")
        guard let formatted else { return ("", []) }
        let text = formatted.string("text") ?? ""
        var entities: [Entity] = []
        for any in formatted.array("entities") ?? [] {
            guard let entity = any as? JSONObject, let offset = entity.int("offset"), let length = entity.int("length"),
                  let type = entity.object("type") else { continue }
            switch type.type {
            case "textEntityTypeMention": entities.append(Entity(type: .mention, offset: offset, length: length))
            case "textEntityTypeMentionName": entities.append(Entity(type: .textMention, offset: offset, length: length, userId: type.int64("user_id")))
            case "textEntityTypeHashtag": entities.append(Entity(type: .hashtag, offset: offset, length: length))
            case "textEntityTypeCashtag": entities.append(Entity(type: .cashtag, offset: offset, length: length))
            case "textEntityTypeUrl": entities.append(Entity(type: .url, offset: offset, length: length))
            case "textEntityTypeTextUrl": entities.append(Entity(type: .textLink, offset: offset, length: length, url: type.string("url")))
            case "textEntityTypeBotCommand": entities.append(Entity(type: .botCommand, offset: offset, length: length))
            case "textEntityTypeEmailAddress": entities.append(Entity(type: .email, offset: offset, length: length))
            default: continue
            }
        }
        entities.sort { ($0.offset, $0.length) < ($1.offset, $1.length) }
        return (text, entities)
    }

    /// The media object (zero or one) of a message content, and the index records for it.
    static func media(of content: JSONObject) -> ([Media], [MediaRecord]) {
        func record(_ file: JSONObject?, kind: MediaKind, mime: String?, width: Int?, height: Int?, duration: Int?, fileName: String?) -> MediaRecord? {
            guard let file, let remote = file.object("remote"), let uniqueId = remote.string("unique_id"), !uniqueId.isEmpty,
                  let remoteId = remote.string("id") else { return nil }
            let size = file.int64("size").flatMap { $0 > 0 ? $0 : nil } ?? file.int64("expected_size").flatMap { $0 > 0 ? $0 : nil }
            let media = Media(
                mediaId: Identifiers.mediaId(uniqueId: uniqueId), kind: kind, mime: mime.flatMap { $0.isEmpty ? nil : $0 },
                size: size, width: width, height: height, durationSeconds: duration, fileName: fileName.flatMap { $0.isEmpty ? nil : $0 }
            )
            return MediaRecord(media: media, remoteId: remoteId, uniqueId: uniqueId)
        }
        let r: MediaRecord?
        switch content.type {
        case "messagePhoto":
            guard let size = largestPhotoSize(content.object("photo")) else { return ([], []) }
            r = record(size.object("photo"), kind: .photo, mime: "image/jpeg", width: size.int("width"), height: size.int("height"), duration: nil, fileName: nil)
        case "messageVideo":
            let v = content.object("video")
            r = record(v?.object("video"), kind: .video, mime: v?.string("mime_type"), width: v?.int("width"), height: v?.int("height"), duration: v?.int("duration"), fileName: v?.string("file_name"))
        case "messageDocument":
            let d = content.object("document")
            r = record(d?.object("document"), kind: .document, mime: d?.string("mime_type"), width: nil, height: nil, duration: nil, fileName: d?.string("file_name"))
        case "messageAudio":
            let a = content.object("audio")
            r = record(a?.object("audio"), kind: .audio, mime: a?.string("mime_type"), width: nil, height: nil, duration: a?.int("duration"), fileName: a?.string("file_name"))
        case "messageVoiceNote":
            let v = content.object("voice_note")
            r = record(v?.object("voice"), kind: .voice, mime: v?.string("mime_type"), width: nil, height: nil, duration: v?.int("duration"), fileName: nil)
        case "messageVideoNote":
            let v = content.object("video_note")
            let length = v?.int("length")
            r = record(v?.object("video"), kind: .videoNote, mime: "video/mp4", width: length, height: length, duration: v?.int("duration"), fileName: nil)
        case "messageSticker":
            let s = content.object("sticker")
            let mime: String? = switch s?.object("format")?.type {
            case "stickerFormatWebp": "image/webp"
            case "stickerFormatTgs": "application/x-tgsticker"
            case "stickerFormatWebm": "video/webm"
            default: nil
            }
            r = record(s?.object("sticker"), kind: .sticker, mime: mime, width: s?.int("width"), height: s?.int("height"), duration: nil, fileName: nil)
        case "messageAnimation":
            let a = content.object("animation")
            r = record(a?.object("animation"), kind: .animation, mime: a?.string("mime_type"), width: a?.int("width"), height: a?.int("height"), duration: a?.int("duration"), fileName: a?.string("file_name"))
        default:
            r = nil
        }
        guard let r else { return ([], []) }
        return ([r.media], [r])
    }

    static func largestPhotoSize(_ photo: JSONObject?) -> JSONObject? {
        let sizes = (photo?.array("sizes") ?? []).compactMap { $0 as? JSONObject }
        return sizes.max { ($0.int("width") ?? 0) * ($0.int("height") ?? 0) < ($1.int("width") ?? 0) * ($1.int("height") ?? 0) }
    }

    // MARK: Chats and users

    /// The full chat object from TDLib's cache: `getChat`, then the type-specific object for
    /// username and member count. `refresh` bypasses the memo. Throws `chat_not_monitorable`
    /// for secret chats and for ids TDLib does not know.
    public func chatInfo(_ chatId: Int64, refresh: Bool = false) async throws -> ChatInfo {
        if !refresh, let cached = chatCache[chatId] { return cached }
        let chat: JSONObject
        do {
            chat = try await tdlib.request("getChat", ["chat_id": chatId]).object
        } catch let error as TDLibError where error.code == 400 || error.code == 404 {
            throw APIError.chatNotMonitorable(chatId)
        }
        let title = chat.string("title") ?? ""
        var photo: ChatPhoto?
        if let big = chat.object("photo")?.object("big"), let uniqueId = big.object("remote")?.string("unique_id"), !uniqueId.isEmpty {
            // chatPhotoInfo carries no dimensions; Telegram's "big" chat photo is 640×640.
            photo = ChatPhoto(mediaId: Identifiers.mediaId(uniqueId: uniqueId), width: 640, height: 640)
        }
        let type = chat.object("type")
        let info: ChatInfo
        switch type?.type {
        case "chatTypePrivate":
            let userId = type?.int64("user_id") ?? chatId
            let sender = try await user(userId)
            info = ChatInfo(id: chatId, type: .private, title: title, username: sender.username, memberCount: nil, photo: photo)
        case "chatTypeBasicGroup":
            var memberCount: Int?
            if let groupId = type?.int64("basic_group_id") {
                let group = try? await tdlib.request("getBasicGroup", ["basic_group_id": groupId]).object
                memberCount = group?.int("member_count").flatMap { $0 > 0 ? $0 : nil }
            }
            info = ChatInfo(id: chatId, type: .basicGroup, title: title, username: nil, memberCount: memberCount, photo: photo)
        case "chatTypeSupergroup":
            var username: String?
            var memberCount: Int?
            if let supergroupId = type?.int64("supergroup_id") {
                let supergroup = try? await tdlib.request("getSupergroup", ["supergroup_id": supergroupId]).object
                username = Translator.username(supergroup?.object("usernames"))
                memberCount = supergroup?.int("member_count").flatMap { $0 > 0 ? $0 : nil }
                if memberCount == nil {
                    let full = try? await tdlib.request("getSupergroupFullInfo", ["supergroup_id": supergroupId]).object
                    memberCount = full?.int("member_count").flatMap { $0 > 0 ? $0 : nil }
                }
            }
            let isChannel = type?.bool("is_channel") ?? false
            info = ChatInfo(id: chatId, type: isChannel ? .channel : .supergroup, title: title, username: username, memberCount: memberCount, photo: photo)
        default:
            throw APIError.chatNotMonitorable(chatId)
        }
        chatCache[chatId] = info
        return info
    }

    /// The chat photo's media index record, if the chat has one (for `GET /v1/media`).
    public func chatPhotoRecord(_ chatId: Int64) async throws -> MediaRecord? {
        let chat = try await tdlib.request("getChat", ["chat_id": chatId]).object
        guard let big = chat.object("photo")?.object("big"), let remote = big.object("remote"),
              let uniqueId = remote.string("unique_id"), !uniqueId.isEmpty, let remoteId = remote.string("id") else { return nil }
        let size = big.int64("size").flatMap { $0 > 0 ? $0 : nil } ?? big.int64("expected_size").flatMap { $0 > 0 ? $0 : nil }
        let media = Media(mediaId: Identifiers.mediaId(uniqueId: uniqueId), kind: .photo, mime: "image/jpeg", size: size, width: 640, height: 640, durationSeconds: nil, fileName: nil)
        return MediaRecord(media: media, remoteId: remoteId, uniqueId: uniqueId)
    }

    /// TDLib's internal id of the chat's last message, for initialising a backfill cursor.
    public func lastMessageId(_ chatId: Int64) async throws -> Int64? {
        let chat = try await tdlib.request("getChat", ["chat_id": chatId]).object
        return chat.object("last_message")?.int64("id")
    }

    public func user(_ userId: Int64) async throws -> Sender {
        if let cached = userCache[userId] { return cached }
        let sender: Sender
        do {
            let user = try await tdlib.request("getUser", ["user_id": userId]).object
            let name = [user.string("first_name"), user.string("last_name")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let isBot = user.object("type")?.type == "userTypeBot"
            sender = Sender(
                type: .user, id: userId, displayName: name.isEmpty ? "Deleted Account" : name,
                username: Translator.username(user.object("usernames")), isBot: isBot
            )
        } catch is TDLibError {
            sender = Sender(type: .user, id: userId, displayName: "Deleted Account", username: nil, isBot: false)
        }
        userCache[userId] = sender
        return sender
    }

    /// The first active username, else the editable one; nil when none.
    static func username(_ usernames: JSONObject?) -> String? {
        guard let usernames else { return nil }
        if let active = usernames.array("active_usernames") as? [String], let first = active.first, !first.isEmpty { return first }
        if let editable = usernames.string("editable_username"), !editable.isEmpty { return editable }
        return nil
    }

    public static func int64(_ any: Any) -> Int64? {
        switch any {
        case let n as Int: Int64(n)
        case let n as Int64: n
        case let n as NSNumber: n.int64Value
        case let s as String: Int64(s)
        default: nil
        }
    }

    // MARK: History

    /// `getChatHistory` → messages, newest first, as TDLib returns them.
    public func history(chatId: Int64, fromInternalId: Int64, offset: Int, limit: Int) async throws -> [TranslatedMessage] {
        let response = try await tdlib.request("getChatHistory", [
            "chat_id": chatId, "from_message_id": fromInternalId, "offset": offset, "limit": limit, "only_local": false,
        ]).object
        var result: [TranslatedMessage] = []
        for any in response.array("messages") ?? [] {
            guard let m = any as? JSONObject else { continue }
            result.append(try await translateMessage(m))
        }
        return result
    }

    /// Forgets memoised chats and users (after reconnecting, so stale titles are not served).
    public func clearCaches() {
        chatCache.removeAll()
        userCache.removeAll()
    }
}
