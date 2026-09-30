import Foundation
import Testing
@testable import TelegramGateway

/// Decoding of the JSON examples in docs/api.md. If the daemon changes a shape, the doc and
/// these fixtures change in the same commit.
@Suite("API decoding")
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIJSON.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test("GET /v1/health")
    func health() throws {
        let health = try decode(Health.self, """
        {
          "status": "ok",
          "version": "0.1.0",
          "started_at": "2026-09-29T09:00:12.004Z",
          "time": "2026-09-29T14:03:37.001Z",
          "tdlib": { "auth_state": "ready", "connection_state": "ready" },
          "head_seq": 4812
        }
        """)
        #expect(health.status == "ok")
        #expect(health.tdlib.authState == .ready)
        #expect(health.tdlib.connectionState == .ready)
        #expect(health.headSeq == 4812)
        #expect(abs(health.startedAt.timeIntervalSince1970 - 1_790_672_412.004) < 0.001)
    }

    @Test("Timestamps with and without fractional seconds")
    func timestamps() throws {
        #expect(RFC3339.parse("2026-09-29T14:03:07Z") != nil)
        #expect(RFC3339.parse("2026-09-29T14:03:07.412Z") != nil)
        #expect(RFC3339.parse("2026-09-29 14:03:07") == nil)
        let whole = try #require(RFC3339.parse("2026-09-29T14:03:07Z"))
        let fractional = try #require(RFC3339.parse("2026-09-29T14:03:07.412Z"))
        #expect(fractional.timeIntervalSince(whole) > 0.41 && fractional.timeIntervalSince(whole) < 0.42)
    }

    @Test("Unknown enum values decode as .unknown")
    func lenientEnums() throws {
        let health = try decode(Health.self, """
        { "status": "degraded", "version": "9", "started_at": "2026-09-29T09:00:12Z", "time": "2026-09-29T14:03:37Z",
          "tdlib": { "auth_state": "wait_teleport", "connection_state": "teleporting" }, "head_seq": 0 }
        """)
        #expect(health.tdlib.authState == .unknown)
        #expect(health.tdlib.connectionState == .unknown)
        let chat = try decode(Chat.self, """
        { "id": "1", "type": "hologram", "title": "x", "username": null, "member_count": null, "is_monitored": false, "photo": null, "future_field": 1 }
        """)
        #expect(chat.type == .unknown)
    }

    @Test("GET /v1/admin/status")
    func adminStatus() throws {
        let status = try decode(AdminStatus.self, """
        {
          "status": "ok", "version": "0.1.0", "started_at": "2026-09-29T09:00:12.004Z", "time": "2026-09-29T14:03:37.001Z",
          "tdlib": { "auth_state": "ready", "connection_state": "updating" }, "head_seq": 4812,
          "account": { "user_id": "123456789", "display_name": "Ada Lovelace", "username": "ada", "phone_last4": "4567" },
          "monitored_chat_count": 2, "grant_count": 1,
          "webhooks": { "active": 1, "retrying": 0, "paused": 0 },
          "events_last_hour": 37, "oldest_seq": 1, "media_cache_bytes": 1048576,
          "backfill": { "in_progress": false, "chats_pending": 0 }
        }
        """)
        #expect(status.account?.username == "ada")
        #expect(status.account?.phoneLast4 == "4567")
        #expect(status.tdlib.connectionState == .updating)
        #expect(status.webhooks.active == 1)
        #expect(status.eventsLastHour == 37)
    }

    @Test("GET /v1/admin/auth in every state")
    func authInfo() throws {
        let qr = try decode(AuthInfo.self, """
        { "auth_state": "wait_qr_confirmation", "qr_link": "tg://login?token=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA", "phone_hint": null }
        """)
        #expect(qr.authState == .waitQRConfirmation)
        #expect(LoginLink.isValid(qr.qrLink ?? ""))
        let code = try decode(AuthInfo.self, """
        { "auth_state": "wait_code", "qr_link": null, "phone_hint": "+1 555 ••• 4567" }
        """)
        #expect(code.authState == .waitCode)
        #expect(code.phoneHint == "+1 555 ••• 4567")
        #expect(code.passwordHint == nil)
        let password = try decode(AuthInfo.self, """
        { "auth_state": "wait_password", "password_hint": "pet" }
        """)
        #expect(password.passwordHint == "pet")
        let ready = try decode(AuthInfo.self, """
        { "auth_state": "ready" }
        """)
        #expect(ready.authState.isLoggedIn)
    }

    @Test("GET /v1/admin/chats?all=true page")
    func chatPage() throws {
        let page = try decode(ChatPage.self, """
        {
          "chats": [
            { "id": "-1001234567890", "type": "channel", "title": "Acme Product Updates", "username": "acmeupdates",
              "member_count": 12840, "is_monitored": true, "photo": { "media_id": "med_3fK9", "width": 640, "height": 640 } },
            { "id": "123456789", "type": "private", "title": "Alice", "username": null, "member_count": null, "is_monitored": false, "photo": null }
          ],
          "has_more": true,
          "next_cursor": "c_MTcyNzYxNDU4Nw"
        }
        """)
        #expect(page.chats.count == 2)
        #expect(page.chats[0].type == .channel)
        #expect(page.chats[0].memberCount == 12840)
        #expect(page.chats[0].photo?.mediaId == "med_3fK9")
        #expect(page.chats[1].type == .private)
        #expect(page.chats[1].memberCount == nil)
        #expect(page.hasMore)
        #expect(page.nextCursor == "c_MTcyNzYxNDU4Nw")
    }

    @Test("GET /v1/admin/folders and monitored-chats")
    func foldersAndMonitored() throws {
        let folders = try decode(FolderList.self, """
        { "folders": [ { "id": "3", "title": "Product", "chat_ids": ["-1001234567890", "-1001987654321"], "is_monitored": true } ] }
        """)
        #expect(folders.folders.first?.chatIds.count == 2)
        let monitored = try decode(MonitoredChats.self, """
        { "chat_ids": ["-1001234567890"], "folder_ids": ["3"], "effective_chat_ids": ["-1001234567890", "-1001987654321"] }
        """)
        #expect(monitored.effectiveChatIds.count == 2)
        #expect(monitored.folderIds == ["3"])
    }

    @Test("PUT /v1/admin/monitored-chats body uses snake_case")
    func monitoredUpdateEncoding() throws {
        let data = try APIJSON.encoder.encode(MonitoredChatsUpdate(chatIds: ["-1"], folderIds: []))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["chat_ids"] as? [String] == ["-1"])
        #expect(object["folder_ids"] as? [String] == [])
    }

    @Test("GET /v1/admin/access-requests")
    func accessRequests() throws {
        let list = try decode(AccessRequestList.self, """
        {
          "access_requests": [
            {
              "request_id": "req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP",
              "status": "pending",
              "name": "Community Analytics",
              "description": "Classifies messages in product channels and counts topics per day.",
              "scopes": ["messages:read", "history:read", "chats:read"],
              "requested_chats": ["-1001234567890", "-1001987654321"],
              "requested_chats_status": [
                { "chat_id": "-1001234567890", "title": "Acme Product Updates", "is_monitored": true },
                { "chat_id": "-1001987654321", "title": "Acme Support", "is_monitored": false }
              ],
              "webhook_url": "https://analytics.example.com/tgw/events",
              "created_at": "2026-09-29T14:03:07Z",
              "expires_at": "2026-09-29T14:18:07Z"
            },
            {
              "request_id": "req_any", "status": "pending", "name": "Anything", "description": "d", "scopes": ["messages:read"],
              "requested_chats": "any", "requested_chats_status": null, "webhook_url": null,
              "created_at": "2026-09-29T14:03:07Z", "expires_at": "2026-09-29T14:18:07Z"
            }
          ]
        }
        """)
        #expect(list.accessRequests.count == 2)
        let first = list.accessRequests[0]
        #expect(first.requestedChats == .list(["-1001234567890", "-1001987654321"]))
        #expect(first.requestedChatsStatus?[1].isMonitored == false)
        #expect(first.webhookUrl == "https://analytics.example.com/tgw/events")
        #expect(first.expiresAt.timeIntervalSince(first.createdAt) == 900)
        let second = list.accessRequests[1]
        #expect(second.requestedChats == .any)
        #expect(second.requestedChatsStatus == nil)
        #expect(second.webhookUrl == nil)
    }

    @Test("Approve body: chat list, folder, scopes")
    func approveEncoding() throws {
        let chats = try APIJSON.encoder.encode(ApproveRequest(selection: .chats(["-1001234567890"]), scopes: ["messages:read", "chats:read"]))
        let chatsObject = try #require(JSONSerialization.jsonObject(with: chats) as? [String: Any])
        #expect(chatsObject["chat_ids"] as? [String] == ["-1001234567890"])
        #expect(chatsObject["folder_id"] == nil)
        #expect(chatsObject["scopes"] as? [String] == ["messages:read", "chats:read"])
        let folder = try APIJSON.encoder.encode(ApproveRequest(selection: .folder("3"), scopes: nil))
        let folderObject = try #require(JSONSerialization.jsonObject(with: folder) as? [String: Any])
        #expect(folderObject["folder_id"] as? String == "3")
        #expect(folderObject["chat_ids"] == nil)
        #expect(folderObject["scopes"] == nil)
    }

    @Test("Grant object with folder and webhook")
    func grant() throws {
        let grant = try decode(Grant.self, """
        {
          "id": "grant_Ab3dE5fG7hJ9kL1m",
          "app": { "name": "Community Analytics", "description": "Classifies messages." },
          "scopes": ["messages:read", "history:read", "chats:read"],
          "chats": { "mode": "folder", "folder_id": "3", "folder_title": "Product" },
          "effective_chat_ids": ["-1001234567890", "-1001987654321"],
          "webhook": {
            "url": "https://analytics.example.com/tgw/events",
            "state": "active",
            "cursor_seq": 4812,
            "pending_events": 0,
            "last_delivery_at": "2026-09-29T14:03:09Z",
            "last_error": null,
            "paused_at": null
          },
          "created_at": "2026-09-29T14:05:40Z",
          "last_seen_at": "2026-09-29T14:07:12Z",
          "revoked_at": null
        }
        """)
        #expect(grant.chats.isFolder)
        #expect(grant.chats.folderTitle == "Product")
        #expect(grant.chats.chatIds == nil)
        #expect(grant.effectiveChatIds.count == 2)
        #expect(grant.webhook?.state == .active)
        #expect(grant.webhook?.cursorSeq == 4812)
        #expect(grant.revokedAt == nil)
        #expect(grant.lastSeenAt != nil)
    }

    @Test("Grant list mode without webhook, and grant detail with stats")
    func grantListAndDetail() throws {
        let list = try decode(GrantList.self, """
        { "grants": [ {
          "id": "grant_1", "app": { "name": "A", "description": "d" }, "scopes": ["messages:read"],
          "chats": { "mode": "list", "chat_ids": ["-1001234567890"] }, "effective_chat_ids": [],
          "webhook": null, "created_at": "2026-09-29T14:05:40Z", "last_seen_at": null, "revoked_at": null } ] }
        """)
        #expect(list.grants[0].chats.isFolder == false)
        #expect(list.grants[0].chats.chatIds == ["-1001234567890"])
        #expect(list.grants[0].webhook == nil)
        let detail = try decode(GrantDetail.self, """
        { "grant": {
          "id": "grant_1", "app": { "name": "A", "description": "d" }, "scopes": ["messages:read"],
          "chats": { "mode": "list", "chat_ids": [] }, "effective_chat_ids": [],
          "webhook": null, "created_at": "2026-09-29T14:05:40Z", "last_seen_at": null, "revoked_at": null },
          "stats": { "events_delivered_24h": 812, "websocket_connections": 1 } }
        """)
        #expect(detail.stats.eventsDelivered24h == 812)
        #expect(detail.stats.websocketConnections == 1)
    }

    @Test("Deliveries")
    func deliveries() throws {
        let list = try decode(DeliveryList.self, """
        { "deliveries": [ { "delivery_id": "dlv_8Kp2mQ9xR4tV7wY1", "first_seq": 4810, "last_seq": 4812, "event_count": 2,
          "attempt": 1, "status": "succeeded", "http_status": 200, "error": null,
          "sent_at": "2026-09-29T14:03:09.117Z", "completed_at": "2026-09-29T14:03:09.402Z" } ], "has_more": false }
        """)
        #expect(list.deliveries[0].status == .succeeded)
        #expect(list.deliveries[0].httpStatus == 200)
        #expect(list.hasMore == false)
    }

    @Test("Error envelope, including the wrong-password hint")
    func errorEnvelope() throws {
        let envelope = try decode(APIError.Envelope.self, """
        {
          "error": {
            "code": "insufficient_scope",
            "message": "This endpoint requires the history:read scope.",
            "details": { "required": "history:read", "granted": ["messages:read", "chats:read"] }
          }
        }
        """)
        #expect(envelope.error.code == "insufficient_scope")
        #expect(envelope.error.details?["required"]?.stringValue == "history:read")
        #expect(envelope.passwordHint == nil)
        let wrongPassword = try decode(APIError.Envelope.self, """
        { "error": { "code": "invalid_request", "message": "Wrong password.", "details": { "field": "password", "reason": "wrong_password" } }, "password_hint": "pet" }
        """)
        #expect(wrongPassword.error.reason == "wrong_password")
        #expect(wrongPassword.passwordHint == "pet")
        let empty = try decode(APIError.Envelope.self, """
        { "error": { "code": "internal", "message": "Bug.", "details": {} } }
        """)
        #expect(empty.error.details?.isEmpty == true)
    }
}
