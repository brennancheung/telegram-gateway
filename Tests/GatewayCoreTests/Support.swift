import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

/// A fully wired core over an in-memory store and a fake TDLib, with a manual clock.
struct Core {
    let store: Store
    let clock: ManualClock
    let tdlib: FakeTDLib
    let translator: Translator
    let eventLog: EventLog
    let grants: Grants
    let accessRequests: AccessRequests
    let monitor: Monitor
    static let adminToken = "tgw_" + String(repeating: "A", count: 43)

    init() async throws {
        store = try Store.inMemory()
        clock = ManualClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        tdlib = FakeTDLib()
        await Fixtures.populate(tdlib)
        translator = Translator(tdlib: tdlib)
        eventLog = EventLog(store: store, clock: clock)
        grants = Grants(store: store, adminToken: Core.adminToken, clock: clock)
        accessRequests = AccessRequests(store: store, grants: grants, clock: clock)
        monitor = Monitor(store: store, eventLog: eventLog, translator: translator, tdlib: tdlib, clock: clock)
        try await monitor.load()
    }

    /// Monitors the channel and the community group explicitly.
    func monitorDefaults() async throws {
        try await monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.channelId, Fixtures.groupId]))
    }

    /// A grant over the given chats with the given scopes; returns the grant and its token.
    func makeGrant(scopes: [Scope] = [.messagesRead, .chatsRead], chats: GrantChats = .list([Fixtures.channelId]), webhook: String? = nil) async throws -> (Grant, String) {
        let issued = try await grants.create(name: "App", description: "Test app", scopes: scopes, chats: chats, webhookUrl: webhook)
        return (issued.grant, issued.token)
    }

    func appendMessageEvent(chatId: Int64 = Fixtures.channelId, id: Int64, text: String = "hi") async throws -> Int64 {
        let chat = ChatSummary(id: chatId, type: .channel, title: "Acme Product Updates", username: "acmeupdates")
        let message = Message(
            id: id, chatId: chatId, sender: Sender(type: .chat, id: chatId, displayName: "Acme Product Updates", username: "acmeupdates", isBot: nil),
            date: clock.now, editDate: nil, isOutgoing: false, text: text, entities: [], replyTo: nil, forwardFrom: nil,
            media: [], mediaGroupId: nil, link: "https://t.me/acmeupdates/\(id)", rawContentType: "messageText"
        )
        return try await eventLog.append(Event(type: .messageNew, occurredAt: clock.now, recordedAt: clock.now, chat: chat, payload: .message(message)))
    }

    func appendChatEvent(chatId: Int64 = Fixtures.groupId) async throws -> Int64 {
        let info = ChatInfo(id: chatId, type: .supergroup, title: "Acme Community", username: "acmecommunity", memberCount: 1, photo: nil)
        return try await eventLog.append(Event(type: .chatUpdated, occurredAt: clock.now, recordedAt: clock.now, chat: info.summary, payload: .chat(info, changes: ["title"])))
    }
}

extension APIError {
    static func ~= (pattern: String, error: APIError) -> Bool { error.code == pattern }
}

/// Runs `body` and returns the `APIError` it threw, failing the test otherwise.
func apiError(_ body: () async throws -> some Any) async -> APIError? {
    do {
        _ = try await body()
        Issue.record("expected an APIError")
        return nil
    } catch let error as APIError {
        return error
    } catch {
        Issue.record("expected an APIError, got \(error)")
        return nil
    }
}
