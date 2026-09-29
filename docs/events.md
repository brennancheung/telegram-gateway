# Events

Everything a consumer receives from the gateway — over the WebSocket, the paged
`GET /v1/events` endpoint, or a webhook — is an **event** in the format defined here. It is
the gateway's own format. The raw JSON of **TDLib** (Telegram's official client library,
which the daemon embeds to speak to Telegram) never crosses the API, so a TDLib upgrade never
breaks a consumer.

How events are fetched is in [api.md](api.md#events); who may see which events is in
[grants.md](grants.md).

## Contents

- [Envelope](#envelope)
- [Event types](#event-types) with one full example each
- [Chat summary](#chat-summary)
- [Message object](#message-object)
- [Sender](#sender)
- [Entities](#entities)
- [Forward origin](#forward-origin)
- [Media object](#media-object)
- [What is not included](#what-is-not-included)
- [Versioning](#versioning)

---

## Envelope

```json
{
  "v": 1,
  "seq": 4810,
  "type": "message.new",
  "occurred_at": "2026-09-29T14:03:07Z",
  "recorded_at": "2026-09-29T14:03:07.412Z",
  "chat": { "id": "-1001234567890", "type": "channel", "title": "Acme Product Updates", "username": "acmeupdates" },
  "message": { … }
}
```

| Field | Type | Meaning |
|---|---|---|
| `v` | number | Format version. Always `1` for this document. See [Versioning](#versioning). |
| `seq` | number | **Sequence number**: the event's position in the gateway's log. Positive, strictly increasing, never reused. An app sees gaps (events for other apps' chats are skipped) but never reordering. This is the consumer's cursor and dedupe key. |
| `type` | string | One of the [event types](#event-types). Consumers must ignore types they do not know. |
| `occurred_at` | timestamp | When the thing happened according to Telegram where Telegram says (message date, edit date); otherwise when the gateway learned of it. |
| `recorded_at` | timestamp | When the gateway appended the event to its log. `recorded_at - occurred_at` is the delivery lag; after the Mac was asleep it can be hours (see "Backfill after gaps" in [design.md](design.md#delivery)). |
| `chat` | object | The [chat summary](#chat-summary) the event belongs to. Present on every event. |
| one payload field | object | Named after the type's first segment: `message` for `message.*`, absent for `message.deleted` which uses `message_ids`, `chat` (the full object) for `chat.updated`, `monitoring` for `monitoring.*`. Listed per type below. |

Timestamps are RFC 3339 UTC (see [api.md](api.md#timestamps)); ids are strings
(see [api.md](api.md#identifiers-are-strings)).

---

## Event types

| Type | Payload | Emitted when | Needs scope |
|---|---|---|---|
| `message.new` | `message` | A message arrives in a monitored chat (including the owner's own outgoing messages, `is_outgoing: true`), and for each message found by backfill after a gap. | `messages:read` |
| `message.edited` | `message` | A message's text, caption or media changed. The full message is sent, not a diff. | `messages:read` |
| `message.deleted` | `message_ids` | Messages were deleted for everyone. | `messages:read` |
| `chat.updated` | `chat`, `changes` | The chat's title, username, photo or member count changed. | `chats:read` |
| `monitoring.started` | `monitoring` | The chat entered the monitored set (owner added it, or it joined a monitored folder). | `chats:read` |
| `monitoring.stopped` | `monitoring` | The chat left the monitored set. | `chats:read` |

An app whose grant lacks `chats:read` never receives `chat.updated` or `monitoring.*`; it can
still call `GET /v1/me` to see its `effective_chat_ids`.

### `message.new`

```json
{
  "v": 1,
  "seq": 4810,
  "type": "message.new",
  "occurred_at": "2026-09-29T14:03:07Z",
  "recorded_at": "2026-09-29T14:03:07.412Z",
  "chat": { "id": "-1001234567890", "type": "supergroup", "title": "Acme Community", "username": "acmecommunity" },
  "message": {
    "id": "1523",
    "chat_id": "-1001234567890",
    "sender": { "type": "user", "id": "123456789", "display_name": "Ada Lovelace", "username": "ada", "is_bot": false },
    "date": "2026-09-29T14:03:07Z",
    "edit_date": null,
    "is_outgoing": false,
    "text": "@acmebot the export in v2.3 fails on large files, see https://acme.example/issues/812 #bug",
    "entities": [
      { "type": "mention", "offset": 0, "length": 8 },
      { "type": "url", "offset": 49, "length": 30 },
      { "type": "hashtag", "offset": 80, "length": 4 }
    ],
    "reply_to": { "chat_id": "-1001234567890", "message_id": "1519" },
    "forward_from": null,
    "media": [],
    "media_group_id": null,
    "link": "https://t.me/acmecommunity/1523",
    "raw_content_type": "messageText"
  }
}
```

A message with a photo and a caption:

```json
{
  "v": 1,
  "seq": 4811,
  "type": "message.new",
  "occurred_at": "2026-09-29T14:03:20Z",
  "recorded_at": "2026-09-29T14:03:20.088Z",
  "chat": { "id": "-1001234567890", "type": "channel", "title": "Acme Product Updates", "username": "acmeupdates" },
  "message": {
    "id": "412",
    "chat_id": "-1001234567890",
    "sender": { "type": "chat", "id": "-1001234567890", "display_name": "Acme Product Updates", "username": "acmeupdates" },
    "date": "2026-09-29T14:03:20Z",
    "edit_date": null,
    "is_outgoing": false,
    "text": "v2.4 is out. Release notes: https://acme.example/releases/2.4",
    "entities": [ { "type": "url", "offset": 28, "length": 33 } ],
    "reply_to": null,
    "forward_from": null,
    "media": [
      {
        "media_id": "med_3fK9pQ2mR7tV1wX5yZ8aB4cD6eF0gH2j",
        "kind": "photo",
        "mime": "image/jpeg",
        "size": 184320,
        "width": 1280,
        "height": 720,
        "duration_seconds": null,
        "file_name": null
      }
    ],
    "media_group_id": null,
    "link": "https://t.me/acmeupdates/412",
    "raw_content_type": "messagePhoto"
  }
}
```

### `message.edited`

Same payload as `message.new`; `edit_date` is set and `occurred_at` equals it. Telegram does
not say what changed; compare with what you stored. Edits of messages the app never saw (sent
before monitoring started) are delivered too — a consumer may see `message.edited` for an
unknown id and should treat it as an upsert.

```json
{
  "v": 1,
  "seq": 4812,
  "type": "message.edited",
  "occurred_at": "2026-09-29T14:05:02Z",
  "recorded_at": "2026-09-29T14:05:02.230Z",
  "chat": { "id": "-1001234567890", "type": "supergroup", "title": "Acme Community", "username": "acmecommunity" },
  "message": {
    "id": "1523",
    "chat_id": "-1001234567890",
    "sender": { "type": "user", "id": "123456789", "display_name": "Ada Lovelace", "username": "ada", "is_bot": false },
    "date": "2026-09-29T14:03:07Z",
    "edit_date": "2026-09-29T14:05:02Z",
    "is_outgoing": false,
    "text": "@acmebot the export in v2.3 fails on files over 1 GB, see https://acme.example/issues/812 #bug",
    "entities": [
      { "type": "mention", "offset": 0, "length": 8 },
      { "type": "url", "offset": 58, "length": 30 },
      { "type": "hashtag", "offset": 89, "length": 4 }
    ],
    "reply_to": { "chat_id": "-1001234567890", "message_id": "1519" },
    "forward_from": null,
    "media": [],
    "media_group_id": null,
    "link": "https://t.me/acmecommunity/1523",
    "raw_content_type": "messageText"
  }
}
```

### `message.deleted`

Telegram reports deletions in batches and without content. Only deletions "for everyone" are
emitted (Telegram also has local-only deletions, which the gateway ignores). Ids may refer to
messages the app never received.

```json
{
  "v": 1,
  "seq": 4813,
  "type": "message.deleted",
  "occurred_at": "2026-09-29T14:06:41.900Z",
  "recorded_at": "2026-09-29T14:06:41.903Z",
  "chat": { "id": "-1001234567890", "type": "supergroup", "title": "Acme Community", "username": "acmecommunity" },
  "message_ids": ["1520", "1521"]
}
```

### `chat.updated`

`chat` is the full [chat object](api.md#the-chat-object) after the change; `changes` lists
which of `title`, `username`, `photo`, `member_count` changed. Member count updates are
coalesced: at most one `chat.updated` per chat per `05:00` for `member_count` alone.

```json
{
  "v": 1,
  "seq": 4814,
  "type": "chat.updated",
  "occurred_at": "2026-09-29T14:10:00.512Z",
  "recorded_at": "2026-09-29T14:10:00.515Z",
  "chat": {
    "id": "-1001234567890",
    "type": "supergroup",
    "title": "Acme Community (official)",
    "username": "acmecommunity",
    "member_count": 12841,
    "is_monitored": true,
    "photo": { "media_id": "med_9aB2cD4eF6gH8jK0lM2nP4qR6sT8uV0w", "width": 640, "height": 640 }
  },
  "changes": ["title", "member_count"]
}
```

### `monitoring.started` / `monitoring.stopped`

Emitted when the owner changes the monitored set, or a monitored folder's membership changes.
An app receives them for chats in its grant (list or folder), so it learns when its coverage
starts and stops. `source` is `"chat"` (the owner monitored this chat explicitly) or
`"folder"` (with `folder_id`). `occurred_at` is the moment of the change; for
`monitoring.started`, messages from this moment on are delivered as `message.new`; earlier
ones are reachable only via [history](api.md#history).

```json
{
  "v": 1,
  "seq": 4815,
  "type": "monitoring.started",
  "occurred_at": "2026-09-29T14:12:30.001Z",
  "recorded_at": "2026-09-29T14:12:30.004Z",
  "chat": { "id": "-1001987654321", "type": "channel", "title": "Acme Support", "username": "acmesupport" },
  "monitoring": { "source": "folder", "folder_id": "3", "folder_title": "Product" }
}
```

```json
{
  "v": 1,
  "seq": 4901,
  "type": "monitoring.stopped",
  "occurred_at": "2026-09-30T08:00:00.120Z",
  "recorded_at": "2026-09-30T08:00:00.121Z",
  "chat": { "id": "-1001987654321", "type": "channel", "title": "Acme Support", "username": "acmesupport" },
  "monitoring": { "source": "chat", "folder_id": null, "folder_title": null }
}
```

---

## Chat summary

The `chat` field on `message.*` and `monitoring.*` events is a summary, enough to route and
label without a lookup:

```json
{ "id": "-1001234567890", "type": "supergroup", "title": "Acme Community", "username": "acmecommunity" }
```

`type` is `private`, `basic_group`, `supergroup` or `channel` (defined in
[api.md](api.md#chat-ids)). `username` is `null` when the chat has none. The full chat
object (member count, photo, `is_monitored`) is in `chat.updated` and at `GET /v1/chats`.

---

## Message object

The same object appears in `message.new`, `message.edited`, and
`GET /v1/chats/{chat_id}/messages`.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Message id, unique within the chat (see [api.md](api.md#message-ids)). Increases with time within a chat, but is not contiguous. |
| `chat_id` | string | The chat's id (repeated from the envelope so the object is self-contained in history responses). |
| `sender` | object | Who sent it — see [Sender](#sender). |
| `date` | timestamp | When it was sent (Telegram's server time, whole seconds). |
| `edit_date` | timestamp or null | When it was last edited. |
| `is_outgoing` | boolean | `true` when the owner's own account sent it. |
| `text` | string | The message text, or the **caption** for a media message; `""` when neither. Plain text: formatting (bold, italic, code) is stripped; the [entities](#entities) that matter for consumers are kept with offsets. |
| `entities` | array | See [Entities](#entities). Empty array when none. |
| `reply_to` | object or null | `{ "chat_id", "message_id" }` of the message this replies to. Usually the same chat; a reply can point at a message in another chat (a channel's linked discussion), hence `chat_id`. The replied-to message is not included; fetch it via history if needed. |
| `forward_from` | object or null | Where a forwarded message came from — see [Forward origin](#forward-origin). |
| `media` | array | Zero or one [media object](#media-object). (Telegram allows one file per message; an "album" is several messages sharing a `media_group_id`.) An array so a future format can carry more without a breaking change. |
| `media_group_id` | string or null | Set when the message is part of an album; all messages of the album share it and arrive as separate `message.new` events. |
| `link` | string or null | `https://t.me/<username>/<id>` when the chat has a public username; otherwise `null`. |
| `raw_content_type` | string | TDLib's `messageContent` type name (`messageText`, `messagePhoto`, `messagePoll`, `messagePinMessage`, …). **Unstable escape hatch**: it tells a consumer *what kind* of message it is looking at when the gateway does not model the content (a poll, a pinned-message notice, a location). Its values follow TDLib and may change when the pinned TDLib commit is bumped. Do not build logic on it beyond logging and counting. |

Messages the gateway does not model (polls, locations, contacts, service messages like
"X joined the group", stickers' emoji) still produce a `message.new` with `text: ""` (or the
caption if any), `media: []` (or the sticker/file), and `raw_content_type` naming the kind.
The gateway never drops a message from a monitored chat.

---

## Sender

```json
{ "type": "user", "id": "123456789", "display_name": "Ada Lovelace", "username": "ada", "is_bot": false }
```

```json
{ "type": "chat", "id": "-1001234567890", "display_name": "Acme Product Updates", "username": "acmeupdates" }
```

| Field | Meaning |
|---|---|
| `type` | `user` — a person or bot. `chat` — a channel posting under its own name, or a group admin posting anonymously (Telegram attributes those to the group itself). |
| `id` | User id (positive) or chat id. |
| `display_name` | The user's first and last name joined with a space, or the chat's title. Never empty (falls back to `"Deleted Account"` for users Telegram no longer resolves). |
| `username` | Public handle without `@`, or `null`. |
| `is_bot` | Present only for `type: "user"`. |

---

## Entities

An **entity** is a span of the text with a meaning. Telegram provides many (bold, italic,
spoiler…); the gateway keeps the subset a consumer routes on:

| `type` | Span means | Extra field |
|---|---|---|
| `mention` | `@username` in the text | |
| `text_mention` | A user mentioned by name without a username | `user_id` |
| `hashtag` | `#tag` | |
| `cashtag` | `$TICKER` | |
| `url` | A URL written in the text | |
| `text_link` | Text that links somewhere else (the URL is not in the text) | `url` |
| `bot_command` | `/command` | |
| `email` | An email address | |

Each entity has `offset` and `length`. **Offsets are in UTF-16 code units**, the way Telegram
defines them and the way JavaScript's `String.prototype.slice` counts. In Python, convert
with `text.encode("utf-16-le")` and slice at `offset * 2` (an emoji before an entity shifts
its offset by 2, not 1). Entities are sorted by `offset` and do not overlap.

---

## Forward origin

```json
{ "type": "chat", "id": "-1001111111111", "display_name": "Some Channel", "username": "somechannel", "message_id": "88", "date": "2026-09-28T19:20:00Z" }
```

| `type` | Means | Fields present |
|---|---|---|
| `user` | Forwarded from a user | `id`, `display_name`, `username`, `date` |
| `chat` | Forwarded from a channel or group post | `id`, `display_name`, `username`, `message_id` (in the origin chat), `date` |
| `hidden_user` | The origin user hides their account when forwarded | `display_name` (the name shown), `date` |

`date` is when the original was sent. `id`, `username`, `message_id` are `null` when not
applicable.

---

## Media object

```json
{
  "media_id": "med_3fK9pQ2mR7tV1wX5yZ8aB4cD6eF0gH2j",
  "kind": "video",
  "mime": "video/mp4",
  "size": 20971520,
  "width": 1920,
  "height": 1080,
  "duration_seconds": 42,
  "file_name": "demo.mp4"
}
```

| Field | Type | Meaning |
|---|---|---|
| `media_id` | string | Opaque, stable per Telegram file. Fetch the bytes at `GET /v1/media/{media_id}` ([api.md](api.md#media)) with `media:read`. |
| `kind` | string | `photo`, `video`, `document`, `audio` (music), `voice` (voice note), `video_note` (round video), `sticker`, `animation` (GIF-like). Consumers must tolerate new kinds. |
| `mime` | string or null | MIME type when Telegram reports one (`image/jpeg` for photos). |
| `size` | number or null | Bytes, when known before download. |
| `width`, `height` | number or null | Pixels for photos, videos, stickers, animations; `null` otherwise. For a photo, the largest size Telegram offers; that is the size served. |
| `duration_seconds` | number or null | Whole seconds for video, audio, voice, video_note, animation. |
| `file_name` | string or null | The original file name for documents, audio and video when the sender's client supplied one. |

The caption of a media message is the message's `text`, not a field of the media object,
so text-processing code is the same for every message.

A chat's `photo` (in the [chat object](api.md#the-chat-object)) is a reduced media reference:
`{ "media_id", "width", "height" }`, always a JPEG.

---

## What is not included

Deliberately absent from format version 1, so a consumer does not go looking:

- **Reactions** (emoji reactions on messages) and **view counts** of channel posts.
- **Polls**: a poll message has `raw_content_type: "messagePoll"` and empty `text`; options
  and votes are not exposed.
- **Formatting** entities (bold, italic, code, spoiler, underline, strikethrough) — `text`
  is plain.
- **Forum topics** (threads inside a supergroup): messages carry no topic id.
- **Read state**, **pinned** flags, **scheduled** messages, **message threads/comments**
  beyond `reply_to`.
- **Private chats and unmonitored groups** — not a format limitation; they never leave the
  gateway ([grants.md](grants.md#privacy-principles)).
- **Anything about the owner's account** beyond `is_outgoing`.

If a consumer needs one of these, the format grows additively (below); nothing here is
blocked by design, only by v1 scope.

---

## Versioning

Every event, and every webhook body, carries `"v": 1`. The API path (`/v1/…`) and the event
format version move together.

**Additive changes** keep `v: 1` and may appear at any time without notice:

- new fields on any object (with `null` when unknown for older events)
- new event types
- new `entities[].type`, `media[].kind`, `forward_from.type`, `sender.type` values
- new `raw_content_type` values (these follow TDLib and are not part of the contract at all)

Therefore a consumer **must**: ignore unknown fields, ignore unknown event types, and treat
enumerations as open (a `switch` with a default that logs and continues).

**Breaking changes** — removing or renaming a field, changing a type (for example a string to
an object), changing the meaning of `seq` or `since`, changing offset units — bump `v` to `2`
and are served only under `/v2/…`. `/v1/…` keeps serving `v: 1` events, including events
recorded after v2 exists, for as long as v1 is supported; a deprecation is announced in this
file with a date at least 90 days out. Events recorded under v1 remain readable under v2 (the
gateway renders from stored data, not from cached JSON).
