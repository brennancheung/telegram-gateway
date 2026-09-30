# API

The gateway daemon serves an HTTP and WebSocket API on the loopback interface only:

```
http://127.0.0.1:41414
```

This document is the contract for that API. The event objects it carries are defined in
[events.md](events.md); the access model (who may see what) in [grants.md](grants.md); a
step-by-step guide for building a consumer in [integrating.md](integrating.md).

Durations in this document are written `mm:ss` (or `h:mm:ss` past an hour); values under a
minute are written as seconds, e.g. `10s`.

## Contents

- [Conventions](#conventions)
- [Authentication](#authentication)
- [Errors](#errors)
- [Access requests](#access-requests) — how an application obtains a token
- [Grants and `/v1/me`](#grants)
- [Chats, folders, monitored chats](#chats)
- [Events](#events) — paged backlog and WebSocket stream
- [History](#history)
- [Media](#media)
- [Webhooks](#webhooks)
- [Health and admin status](#health)
- [Admin: login](#admin-login)
- [Admin: pruning](#admin-pruning)
- [Rate limits](#rate-limits)
- [Endpoint index](#endpoint-index)

---

## Conventions

### Port and configuration

The default port is **41414**. It is set in the daemon's configuration file:

```
~/Library/Application Support/TelegramGateway/config.json
```

```json
{
  "port": 41414,
  "events_retention_days": null,
  "media_cache_max_bytes": 2147483648
}
```

The environment variable `TGW_PORT` overrides `port` for the process it is set on (used in
development to run a second daemon). `TGW_HOME` overrides the data directory itself (default
`~/Library/Application Support/TelegramGateway`). The `tgw` command-line tool and the menu bar
app read the same file, so they always find the daemon. The daemon binds `127.0.0.1` only and
never `0.0.0.0`; there is no TLS because nothing leaves the machine except webhooks.

### JSON

- Requests and responses are `application/json; charset=utf-8`. Send `Content-Type` on every
  request with a body.
- **Unknown fields must be ignored** by consumers. The gateway adds fields without notice
  (see "Versioning" in [events.md](events.md#versioning)).
- Absent optional values are `null`, never omitted, so a field's presence is stable.
- Every response carries `X-TGW-Request-Id`; quote it when reporting a problem.

### Identifiers are strings

Every identifier that originates in Telegram — chat id, message id, user id, folder id — is
encoded as a **JSON string**, e.g. `"chat_id": "-1001234567890"`. Telegram defines these as
64-bit signed integers. JavaScript (and any JSON parser that maps numbers to IEEE doubles)
silently loses precision above 2^53. Today's Telegram ids happen to fit, but the type is
int64 by contract and nothing in a consumer should ever do arithmetic on an id, so the gateway
removes the hazard rather than documenting it. Compare ids as strings; never parse them.

The gateway's own counters — `seq` (sequence number), `limit`, sizes, counts — are JSON
numbers. They are small and consumers do arithmetic on them (`seq + 1`).

The gateway's own opaque identifiers are strings with a prefix that names their kind:
`req_…` (access request), `grant_…` (grant), `dlv_…` (webhook delivery), `med_…` (media).

### Chat ids

A **chat** is anything that has a message timeline in Telegram: a private conversation with
a user, a group, or a channel. A **chat id** is Telegram's number for it, and its sign and
magnitude encode the kind:

| Chat type (`type` field) | What it is | Chat id looks like |
|---|---|---|
| `private` | One-to-one chat with a user (or a bot) | positive: `"123456789"` (equals the user's id) |
| `basic_group` | Small group (up to 200 members, legacy kind) | negative: `"-987654321"` |
| `supergroup` | Large group | `"-100…"`: `"-1001234567890"` |
| `channel` | Broadcast channel: only admins post, everyone else reads | `"-100…"`: `"-1001987654321"` |

Telegram calls both supergroups and channels "supergroups" internally and distinguishes them
with a flag; the gateway exposes them as two `type` values because consumers care about the
difference (a channel has no conversation; a supergroup does). **Secret chats** (end-to-end
encrypted private chats) cannot be monitored and never appear in this API.

### Message ids

A **message id** identifies a message within its chat (it is not globally unique: message
`"1523"` exists in every chat). The gateway uses Telegram's public message id — the number
that appears in `https://t.me/<username>/<message id>` links and in Telegram's Bot API.
Implementation note for the daemon: TDLib's internal message id is this number shifted left
by 20 bits; the gateway converts at the boundary and consumers never see the internal form.

### Timestamps

RFC 3339 in UTC with a `Z` suffix: `"2026-09-29T14:03:07Z"`. Values that originate in
Telegram have whole-second precision. Values the gateway generates may carry up to three
fractional digits: `"2026-09-29T14:03:07.412Z"`. Parsers must accept both.

### Pagination

List endpoints take `limit` (a JSON number, capped per endpoint) and return `has_more`
(boolean) plus a cursor field named for the endpoint: `next_since` for events, `next_before`
for history, `next_cursor` for the admin chat list. When `has_more` is false the cursor field
is still present and still valid (it is where a later call should continue from).

### CORS

None. The API is for local processes, not web pages; the daemon sends no CORS headers and
rejects preflight requests with 404.

---

## Authentication

Every endpoint except `GET /v1/health`, `POST /v1/access-requests` and
`GET /v1/access-requests/{id}` requires:

```
Authorization: Bearer tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV
```

A **token** is `tgw_` followed by 43 characters of base64url (32 random bytes from the
system CSPRNG). The gateway stores only the SHA-256 hash of each token (plus, for an app
token, the plain value inside its access request during the `10:00` hand-out window after
approval, erased with the request); a token that is lost cannot be recovered, only replaced.

There are two kinds of token. They look identical; the gateway tells them apart by lookup.

| Kind | Who holds it | Can call | How it is issued |
|---|---|---|---|
| **Admin token** | The menu bar app and the `tgw` CLI | Everything, including `/v1/admin/*` | Generated by the daemon on first run and written to the login Keychain (service `TelegramGateway`, account `admin-token`). There is exactly one; the daemon regenerates it on request (`tgw`) and the old one stops working. |
| **App token** | One application | Non-admin endpoints, limited by the app's grant (scopes and chats) | Issued when the owner approves an [access request](#access-requests). One per grant. |

An admin token calling a non-admin endpoint (for example `GET /v1/chats`) sees everything the
gateway knows, as if it held every scope for every monitored chat. `GET /v1/me` with an admin
token returns a synthetic grant with `"id": "grant_admin"`.

### Authentication errors

| HTTP | `error.code` | When |
|---|---|---|
| 401 | `missing_token` | No `Authorization` header, or not `Bearer`. |
| 401 | `invalid_token` | Malformed, or hash not found. |
| 401 | `token_revoked` | The grant behind this token was revoked. The body carries `details.revoked_at`. |
| 403 | `admin_only` | App token on an `/v1/admin/*` endpoint. |
| 403 | `insufficient_scope` | Grant lacks the scope; `details.required` names it (`"history:read"`). |
| 403 | `chat_not_granted` | The chat exists but is outside the grant, or is no longer monitored. The gateway never distinguishes "not granted" from "does not exist" for app tokens: an unknown chat id is also `403 chat_not_granted`, so a token cannot enumerate chats it cannot see. |

Example:

```json
{
  "error": {
    "code": "insufficient_scope",
    "message": "This endpoint requires the history:read scope.",
    "details": { "required": "history:read", "granted": ["messages:read", "chats:read"] }
  }
}
```

---

## Errors

Every non-2xx response has this body:

```json
{
  "error": {
    "code": "rate_limited",
    "message": "Human-readable explanation, safe to log.",
    "details": {}
  }
}
```

`code` is stable and is what consumers branch on; `message` is free text; `details` is an
object (possibly empty) whose keys are listed per code below.

| HTTP | `error.code` | Meaning | `details` |
|---|---|---|---|
| 400 | `invalid_request` | Body or query fails validation. | `field`, `reason` |
| 400 | `scope_not_available` | Requested `messages:send` (reserved, not implemented). | `scope` |
| 400 | `scope_not_requested` | Approval tried to grant a scope the app did not ask for. | `scope` |
| 400 | `chat_not_monitored` | Approval names a chat that is not monitored; monitor it first. | `chat_id` |
| 400 | `folder_not_monitored` | Approval names a folder that is not monitored. | `folder_id` |
| 400 | `chat_not_monitorable` | Attempt to monitor a secret chat or an unknown chat. | `chat_id` |
| 401 | see [Authentication](#authentication-errors) | | |
| 403 | see [Authentication](#authentication-errors) | | |
| 404 | `not_found` | Unknown route, id, or a resolved access request that has been purged. | |
| 409 | `already_resolved` | Approve/deny on a request that is no longer pending. | `status` |
| 409 | `webhook_not_paused` | Resume on a webhook that is not paused. | `state` |
| 409 | `webhook_not_configured` | Webhook operation on a grant with no webhook (`404` for `GET /v1/me/webhook`). The admin token has no webhook. | |
| 410 | `history_pruned` | `since` is older than the oldest retained event. | `oldest_seq` |
| 410 | `media_gone` | The file can no longer be obtained from Telegram (message deleted, or Telegram expired it). | `media_id` |
| 413 | `payload_too_large` | Request body over 64 KiB. | |
| 429 | `rate_limited` | See [Rate limits](#rate-limits). `Retry-After` header is set (seconds). | `retry_after` |
| 500 | `internal` | Bug. Report with `X-TGW-Request-Id`. | |
| 503 | `not_logged_in` | The gateway has no Telegram session yet (owner has not logged in). | `auth_state` |
| 503 | `telegram_unavailable` | Endpoint needs Telegram live (history, media, folders) and the connection is down. Endpoints served from the gateway's own store (events, chats, grants) keep working. | `connection_state` |

---

## Access requests

An application gets a token through a **device-code style** flow: it asks, the owner approves
in the menu bar app, and the application, polling, receives the token. No browser, no
redirect. The application never sees the owner's Telegram credentials.

```
app                                  gateway                         owner (menu bar app)
 │ POST /v1/access-requests ───────────▶│                                   │
 │ ◀── {request_id, poll_url, pending} ─│── "Analytics wants access" ──────▶│
 │ GET /v1/access-requests/{id} ───────▶│                                   │
 │ ◀── {status: pending} ───────────────│                                   │
 │        … every 3s …                  │◀──── approve (chats, scopes) ─────│
 │ GET /v1/access-requests/{id} ───────▶│                                   │
 │ ◀── {status: approved, token, grant} │                                   │
```

### `POST /v1/access-requests`

Unauthenticated. Creates a pending request. The `request_id` is a 32-byte random value and
is the only credential needed to poll; treat it as a secret until the flow completes.

Request:

```json
{
  "name": "Community Analytics",
  "description": "Classifies messages in product channels and counts topics per day.",
  "scopes": ["messages:read", "history:read", "chats:read"],
  "requested_chats": ["-1001234567890", "-1001987654321"],
  "webhook": { "url": "https://analytics.example.com/tgw/events" }
}
```

| Field | Required | Rules |
|---|---|---|
| `name` | yes | 1–64 characters. Shown to the owner. |
| `description` | yes | 1–280 characters. Shown to the owner; say what the app does with the messages. |
| `scopes` | yes | Non-empty array of scope names from [grants.md](grants.md#scopes). `messages:send` → `400 scope_not_available`. |
| `requested_chats` | no | Array of chat ids, or the string `"any"`. Default `"any"`. The owner sees this as a suggestion and chooses the actual set; ids that are not monitored are shown to the owner as "not monitored" and can be monitored during approval. |
| `webhook` | no | `{ "url": "https://…" }`. `https` required unless the host is `127.0.0.1`, `localhost` or `::1`. Omit to use WebSocket only; a webhook can be added later with `PUT /v1/me/webhook`. |

Response `201 Created`:

```json
{
  "request_id": "req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP",
  "poll_url": "http://127.0.0.1:41414/v1/access-requests/req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP",
  "status": "pending",
  "expires_at": "2026-09-29T14:18:07Z"
}
```

A pending request expires `15:00` after creation. Rate limit: 10 requests per minute
overall (unauthenticated endpoint).

### `GET /v1/access-requests/{request_id}`

Unauthenticated. Poll no faster than every 2s (faster is `429`); 3s is recommended.

Responses by `status`:

`pending`:

```json
{ "request_id": "req_7Hs2…", "status": "pending", "expires_at": "2026-09-29T14:18:07Z" }
```

`approved` — the token is included on every poll for `10:00` after approval, then the
request is purged and this URL returns `404 not_found`. Persist the token the moment you see
it (see "Token storage" in [grants.md](grants.md#token-storage-for-apps)).

```json
{
  "request_id": "req_7Hs2…",
  "status": "approved",
  "approved_at": "2026-09-29T14:05:40Z",
  "token": "tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV",
  "webhook": {
    "url": "https://analytics.example.com/tgw/events",
    "secret": "whsec_9fA3kLm2Qp7Rt5Vx8Zy1Bc4De6Fg0Hj3Kl5Mn7Op9Qs"
  },
  "grant": {
    "id": "grant_Ab3dE5fG7hJ9kL1m",
    "app": { "name": "Community Analytics", "description": "Classifies messages in product channels and counts topics per day." },
    "scopes": ["messages:read", "history:read", "chats:read"],
    "chats": { "mode": "list", "chat_ids": ["-1001234567890"] },
    "effective_chat_ids": ["-1001234567890"],
    "created_at": "2026-09-29T14:05:40Z",
    "last_seen_at": null,
    "revoked_at": null
  }
}
```

`webhook` is `null` when no webhook was requested. `webhook.secret` (`whsec_` + 43 base64url
characters) is shown here and nowhere else; it signs every delivery (see [Webhooks](#webhooks)).
The owner may have narrowed `scopes` and `chats` relative to what was asked; read `grant`
rather than assuming.

`denied`:

```json
{ "request_id": "req_7Hs2…", "status": "denied", "denied_at": "2026-09-29T14:05:40Z", "reason": "Not now." }
```

`expired`:

```json
{ "request_id": "req_7Hs2…", "status": "expired", "expires_at": "2026-09-29T14:18:07Z" }
```

Denied and expired requests are also purged `10:00` after resolution (`404` afterwards). An
app may simply create a new request.

### Admin side

`GET /v1/admin/access-requests` — pending requests (add `?all=true` for resolved ones still
retained).

```json
{
  "access_requests": [
    {
      "request_id": "req_7Hs2…",
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
    }
  ]
}
```

`requested_chats_status` is `null` when `requested_chats` was `"any"`.

`POST /v1/admin/access-requests/{request_id}/approve` — the owner picks the chats (or one
folder) and optionally narrows the scopes.

```json
{ "chat_ids": ["-1001234567890"], "scopes": ["messages:read", "chats:read"] }
```

or

```json
{ "folder_id": "3" }
```

| Field | Rules |
|---|---|
| `chat_ids` or `folder_id` | Exactly one of them. Every chat must be monitored (`400 chat_not_monitored`); the folder must be monitored (`400 folder_not_monitored`). The menu bar app monitors chats first, then approves, so the owner experiences one click. |
| `scopes` | Optional. Defaults to the requested scopes. Must be a subset of them (`400 scope_not_requested`). |

Response `200` with the grant object (no token: the token goes only to the app, through
polling). `409 already_resolved` if the request is no longer pending.

`POST /v1/admin/access-requests/{request_id}/deny` with `{ "reason": "…" }` (optional
`reason`, shown to the app). Response `200 { "status": "denied" }`.

---

## Grants

A **grant** is one application's access: a token, a set of **scopes** (what kinds of data),
and a set of chats (which chats), see [grants.md](grants.md). The grant object:

```json
{
  "id": "grant_Ab3dE5fG7hJ9kL1m",
  "app": { "name": "Community Analytics", "description": "…" },
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
```

- `chats.mode` is `"list"` (with `chat_ids`) or `"folder"` (with `folder_id`, `folder_title`).
- `effective_chat_ids` is what the grant can see **right now**: the granted chats
  intersected with the monitored set. It changes when the owner changes monitoring or the
  folder's contents change. This is the list consumers should rely on.
- `webhook` is `null` if none; `state` is `active`, `retrying` or `paused` (see [Webhooks](#webhooks)).
  The secret is never included.
- `last_seen_at` is the last authenticated request or WebSocket frame from this token.

### `GET /v1/me`

Any app token. Returns `{ "grant": { … } }` for the calling token. Call it after connecting
and after any `monitoring.*` event to learn current coverage.

### `PUT /v1/me/webhook`

Sets or replaces the webhook URL. Body `{ "url": "https://…" }`. Response `200`:

```json
{ "url": "https://…", "secret": "whsec_…", "state": "active", "cursor_seq": 4812 }
```

A new secret is generated each time; the old one stops working. If the webhook was `paused`
it becomes `active` and delivery continues from `cursor_seq`. When a webhook is created for
the first time on an existing grant, `cursor_seq` starts at the current head (the app gets
new events only; use `GET /v1/events` for the past).

`DELETE /v1/me/webhook` → `204`. Pending deliveries are dropped; the cursor is discarded.

`POST /v1/me/webhook/resume` → `200` with the same body as `PUT`, minus `secret`. Only valid
when `state` is `paused` (`409 webhook_not_paused`).

`GET /v1/me/webhook` → the webhook part of the grant object, or `404 webhook_not_configured`.

### Admin

- `GET /v1/admin/grants` → `{ "grants": [ … ] }`. Add `?include_revoked=true` to include
  revoked grants (kept for 30 days for the activity view, then deleted).
- `GET /v1/admin/grants/{grant_id}` → `{ "grant": { … }, "stats": { "events_delivered_24h": 812, "websocket_connections": 1 } }`.
- `DELETE /v1/admin/grants/{grant_id}` → `204`. Revokes: the token returns `401
  token_revoked`, open WebSockets close with code `4499`, pending webhook deliveries are
  dropped. Effects are immediate and permanent; the app must request access again.
- `POST /v1/admin/grants/{grant_id}/webhook/resume` → same as the app's own resume.
- `GET /v1/admin/grants/{grant_id}/deliveries?limit=50` → recent webhook deliveries, newest
  first: `{ "deliveries": [ { "delivery_id", "first_seq", "last_seq", "event_count",
  "attempt", "status": "succeeded"|"failed"|"in_flight", "http_status", "error",
  "sent_at", "completed_at" } ], "has_more" }`.

---

## Chats

### The chat object

```json
{
  "id": "-1001234567890",
  "type": "channel",
  "title": "Acme Product Updates",
  "username": "acmeupdates",
  "member_count": 12840,
  "is_monitored": true,
  "photo": { "media_id": "med_3fK9…", "width": 640, "height": 640 }
}
```

| Field | Notes |
|---|---|
| `type` | `private`, `basic_group`, `supergroup`, `channel`. |
| `username` | Public handle without `@`; `null` for private chats and groups without one. A chat with a username is reachable at `https://t.me/<username>`. |
| `member_count` | `null` when Telegram does not report it (private chats, and channels the account cannot read the count of). |
| `is_monitored` | Whether the gateway currently watches this chat. For an app this is `false` only for a granted chat that the owner has since un-monitored — the app still sees the chat in its list so it knows coverage was lost. |
| `photo` | The chat's profile photo as a [media reference](events.md#media-object) (largest available size), fetchable with `media:read`; `null` if none. |

### `GET /v1/chats`

Requires `chats:read`. Returns the chats in the grant (list or folder), each with
`is_monitored`. Never paginated (a grant is at most a few hundred chats).

```json
{ "chats": [ { …chat object… } ] }
```

`GET /v1/chats/{chat_id}` → `{ "chat": { … } }`, `403 chat_not_granted` otherwise.

### Admin: chat list, folders, monitored set

`GET /v1/admin/chats` — the monitored chats. `GET /v1/admin/chats?all=true&limit=200&cursor=…`
— every chat in the account's main chat list, ordered as Telegram orders it (most recent
activity first), paginated with `next_cursor` (opaque string; `limit` 1–500, default 200).
Secret chats are omitted. Needs a logged-in daemon (`503 not_logged_in` otherwise).

```json
{ "chats": [ … ], "has_more": true, "next_cursor": "c_MTcyNzYxNDU4Nw" }
```

`GET /v1/admin/folders` — the account's **chat folders**. A folder is a named tab in the
owner's Telegram apps ("Work", "Crypto") that groups chats; the owner edits it on the phone.
The gateway exposes folders so a grant or the monitored set can follow one.

```json
{
  "folders": [
    { "id": "3", "title": "Product", "chat_ids": ["-1001234567890", "-1001987654321"], "is_monitored": true }
  ]
}
```

Folder ids are Telegram's and are strings like every id. Folders that use filters (for
example "all unread") are listed with the chats they currently contain; the gateway
re-evaluates membership when Telegram reports a change.

`GET /v1/admin/monitored-chats`:

```json
{
  "chat_ids": ["-1001234567890"],
  "folder_ids": ["3"],
  "effective_chat_ids": ["-1001234567890", "-1001987654321"]
}
```

`PUT /v1/admin/monitored-chats` with `{ "chat_ids": [ … ], "folder_ids": [ … ] }` replaces
the whole monitored set (both arrays required; empty arrays clear). The effective set is the
union of the explicit chats and every chat in the monitored folders. Response `200` with the
same shape as `GET`. Unknown or secret chats → `400 chat_not_monitorable`; a folder id the
gateway has not seen from Telegram → `400 invalid_request` (`field: "folder_ids"`); validating
a chat needs TDLib, so without a login this is `503 not_logged_in`. Each chat that enters or
leaves the effective set produces a `monitoring.started` / `monitoring.stopped` event
([events.md](events.md)); when one `PUT` both removes and adds chats, the `stopped` events
are recorded before the `started` ones. The daemon begins watching new chats within a few seconds and
backfills from the moment of the change, not before: messages sent to a chat before it was
monitored are available only through [History](#history).

---

## Events

The gateway appends every event to a single **event log** and assigns each a **sequence
number** (`seq`): a positive integer, strictly increasing across the whole log, with no
reuse. The log is one per gateway, so an app sees gaps in the numbers (events for chats
outside its grant are skipped). Within what one app sees, order is by `seq` and never
changes. The event object is defined in [events.md](events.md).

Both endpoints below apply the grant **at read time**: an app receives events for chats in
its current `effective_chat_ids`, and only event types its scopes allow (`message.*` needs
`messages:read`; `chat.updated` and `monitoring.*` need `chats:read`; an app with only
`media:read` gets nothing). Adding a chat to a grant makes that chat's past events readable;
removing it hides them.

### `since` semantics

`since=<seq>` is **exclusive**: the response starts at the first event with `seq > since`.
`since=0` means from the beginning of retained history. A consumer that stores the `seq` of
the last event it processed passes it back unchanged.

### Retention

By default the gateway keeps every event forever (`events_retention_days: null`). The owner
can prune ([Admin: pruning](#admin-pruning)). If a page starting after `since` would skip
pruned events — that is, `since + 1` is lower than the oldest retained `seq` — the request
fails with `410 history_pruned` and `details.oldest_seq`; the consumer decides whether to
continue from `oldest_seq` (accepting a gap) and can fill the gap with [History](#history).
`since = 0` is exempt: it always means "from the beginning of retained history".

### `GET /v1/events`

```
GET /v1/events?since=4700&limit=100&types=message.new,message.edited&chat_id=-1001234567890
```

| Query | Default | Rules |
|---|---|---|
| `since` | `0` | Exclusive lower bound on `seq`. |
| `limit` | `100` | 1–1000. |
| `types` | all | Comma-separated event types to include. |
| `chat_id` | all | One chat id; repeat the parameter for several. |

Response `200`:

```json
{
  "events": [ { "v": 1, "seq": 4701, "type": "message.new", … }, … ],
  "has_more": true,
  "next_since": 4800,
  "head_seq": 4812
}
```

`next_since` is the `seq` of the last event returned (or `since` when `events` is empty);
`head_seq` is the newest `seq` in the whole log, so a consumer can measure how far behind it
is. Events are in ascending `seq`. The response is a page of the log, never a wait: an empty
`events` array means nothing new yet.

### `GET /v1/events/stream` (WebSocket)

Upgrade with the same `Authorization` header (every WebSocket client library for a
non-browser runtime can set headers; browser pages are not supported — see CORS). Query
parameters: `since`, `types`, `chat_id` as above.

```
GET /v1/events/stream?since=4700 HTTP/1.1
Upgrade: websocket
Authorization: Bearer tgw_…
```

If `since` is **omitted**, the stream is live only: no backlog, and the first frame is
`caught_up` with the current head. If `since` is present, the gateway first sends the backlog
in order, then `caught_up`, then live events as they are recorded.

All frames are text frames containing one JSON object with a `type`:

| Frame | Shape | When |
|---|---|---|
| Event | `{ "type": "event", "event": { …event object… } }` | One per event, in `seq` order. |
| Caught up | `{ "type": "caught_up", "seq": 4812 }` | Once, after the backlog (or immediately if there was none). `seq` is the head at that moment. The stream is now live. |
| Heartbeat | `{ "type": "heartbeat", "seq": 4812, "time": "2026-09-29T14:03:37.001Z" }` | Every 30s when no event was sent in the last 30s. `seq` is the current head (across the whole log, so it may exceed the last event this app saw). |
| Error | `{ "type": "error", "code": "history_pruned", "message": "…", "details": { "oldest_seq": 4000 } }` | Immediately before the gateway closes the socket. Codes are the same as HTTP `error.code`. |

The gateway also answers standard WebSocket ping frames with pong. A client should treat the
connection as dead if it has received no frame of any kind for `01:30` and reconnect with the
last `seq` it processed. Reconnecting always re-sends from `since`, so a consumer that
reconnects after processing `seq` 4810 but before persisting it will see 4810 again: dedupe
on `seq` ([integrating.md](integrating.md#dedupe-on-seq)).

Close codes the gateway uses:

| Code | Meaning |
|---|---|
| `1001` | Daemon shutting down (restart or upgrade). Reconnect with backoff. |
| `4400` | The query string is invalid (`since`, `types` or `chat_id`); an error frame precedes it. |
| `4401` | Missing, invalid or revoked token. The upgrade always succeeds; an error frame with the HTTP `error.code` (`missing_token`, `invalid_token`, `token_revoked`) is sent, then this close. (A refused upgrade cannot carry a JSON body, so the WebSocket never answers `401`.) |
| `4403` | Grant lacks `messages:read` and `chats:read` (nothing to stream). |
| `4409` | Too many connections for this token (limit 4). |
| `4429` | The token's request budget (600 per minute) is exhausted; an error frame precedes it. |
| `4410` | `history_pruned` (an error frame precedes it). |
| `4499` | Grant revoked while connected. Do not reconnect. |

There is no acknowledgement from the client: for WebSocket, **the consumer owns the cursor**.
The gateway sends as fast as the socket accepts; if the client falls more than 10 000
events behind the head of the log (the socket is not draining while events keep arriving),
the gateway sends an error frame `slow_consumer` and closes with `1008`. Reconnect with
`since` and the backlog is replayed at whatever pace the client reads.

Up to 4 concurrent WebSocket connections per token, each with its own `since`.

---

## History

`GET /v1/chats/{chat_id}/messages` — requires `history:read`; the chat must be in the grant
(admin: must be monitored).
Reads the chat's timeline **from Telegram** (not from the event log), so it reaches back
before the chat was monitored and before the grant existed — as far as the owner's account
can see. It is slower than the event endpoints and rate-limited more tightly (Telegram
enforces its own limits on history reads).

```
GET /v1/chats/-1001234567890/messages?before=1523&limit=50
```

| Query | Default | Rules |
|---|---|---|
| `before` | newest | Exclusive: return messages with an id lower than this. Omit for the newest messages. |
| `limit` | `50` | 1–100. |

Response `200`, **newest first** (Telegram's natural order for history):

```json
{
  "messages": [ { "id": "1522", "chat_id": "-1001234567890", … }, { "id": "1519", … } ],
  "has_more": true,
  "next_before": "1519"
}
```

Each item is a [message object](events.md#message-object), the same shape as in
`message.new`. Message ids are not contiguous (deleted messages, service messages the
gateway does not expose). `next_before` is the id of the oldest message returned; pass it
as `before` to continue backwards. `has_more` is `true` whenever a full page came back, so
the last page before the beginning of the chat may be followed by one empty page.
`503 telegram_unavailable` when the connection is down.

---

## Media

A **media object** in a message (photo, video, document…) carries a `media_id`. The file
itself is fetched from the gateway, which downloads it from Telegram on first request and
caches it. Media ids are stable: the same Telegram file referenced by two messages has the
same `media_id`.

### `GET /v1/media/{media_id}`

Requires `media:read`; the media must belong to a message (or chat photo) in a chat the grant
can see, otherwise `403 chat_not_granted`.

- If the file is cached: `200` with the bytes. Headers: `Content-Type` (from the media
  object's `mime`, or `application/octet-stream`), `Content-Length`, `Content-Disposition:
  inline; filename="<file_name>"` (when known), `ETag: "<media_id>"`, `Cache-Control:
  private, max-age=31536000, immutable`. `Range` requests are honoured (`206`), so large
  videos can be streamed.
- If not cached: the gateway starts the download and waits up to 30s for it to finish. If it
  finishes, `200` as above. If not, `202 Accepted` with `Retry-After: 5` and body
  `{ "status": "downloading", "media_id": "med_…", "bytes_downloaded": 3145728, "size": 20971520 }`.
  Poll again; each poll waits up to 30s.
- `410 media_gone` when Telegram can no longer serve the file (message deleted, file
  expired). `503 telegram_unavailable` when not cached and the connection is down. A fifth
  concurrent uncached download for one token is `429 rate_limited` with `Retry-After: 5`.
- An unknown media id is `403 chat_not_granted`, like an unknown chat (never `404`).

`HEAD /v1/media/{media_id}` returns the headers without the body (and triggers no download:
`Content-Length` is the size from the media object when known, `X-TGW-Cached: true|false`).
A chat's profile photo is served as `image/jpeg` at Telegram's "big" size, reported as
640×640 (TDLib does not give chat photo dimensions).

### Cache

Files live in TDLib's own `files/` directory under the data directory. When the cache exceeds
`media_cache_max_bytes` (default 2 GiB), the gateway evicts least-recently-served files. An
evicted file is simply downloaded again on the next request. The media object in the event
log is never evicted, only the bytes.

---

## Webhooks

A **webhook** is an HTTPS endpoint an application runs; the gateway `POST`s events to it, so
the application needs no open connection to the gateway and can run on another machine.
Registered in the access request (`webhook.url`) or later with `PUT /v1/me/webhook`.

### What the gateway sends

Deliveries are **batches** of events in `seq` order:

```
POST /tgw/events HTTP/1.1
Host: analytics.example.com
Content-Type: application/json; charset=utf-8
User-Agent: TelegramGateway/1
X-TGW-Delivery-Id: dlv_8Kp2mQ9xR4tV7wY1
X-TGW-Seq: 4812
X-TGW-Attempt: 1
X-TGW-Signature: sha256=5f1a9c…e3b0

{
  "v": 1,
  "delivery_id": "dlv_8Kp2mQ9xR4tV7wY1",
  "grant_id": "grant_Ab3dE5fG7hJ9kL1m",
  "sent_at": "2026-09-29T14:03:09.117Z",
  "events": [
    { "v": 1, "seq": 4810, "type": "message.new", … },
    { "v": 1, "seq": 4812, "type": "message.edited", … }
  ]
}
```

| Header | Meaning |
|---|---|
| `X-TGW-Delivery-Id` | Unique per delivery; the same value on every retry of that delivery. |
| `X-TGW-Seq` | The highest `seq` in the batch. |
| `X-TGW-Attempt` | 1 for the first try, incremented on each retry. |
| `X-TGW-Signature` | `sha256=` + lowercase hex of HMAC-SHA256(key = webhook secret, message = the raw request body bytes exactly as sent). Verify before parsing ([integrating.md](integrating.md#verify-webhook-signatures)). |

Batching: the gateway sends a delivery as soon as there is at least one pending event and
either 100 events are pending or 500 ms have passed since the first pending event. A batch
never exceeds 100 events or 4 MiB of JSON (media bytes are never in webhooks, only
references). A consumer that only ever sees batches of one is normal for quiet chats.

### Success and failure

A delivery **succeeds** when the consumer answers any `2xx` within `10s` of the request being
sent (headers and body fully received). The response body is ignored. Anything else fails:
non-2xx (redirects are not followed and count as failure), connection refused, TLS error,
timeout. Only one delivery is in flight per grant at any time; the next batch is sent only
after the previous one succeeded, which is what guarantees order.

### Retry schedule

On failure the same delivery (same `delivery_id`, same events, incremented `X-TGW-Attempt`;
`sent_at` in the body is the time of this attempt) is retried after a delay:

| Attempt | Delay before it | Elapsed since first failure (approx.) |
|---|---|---|
| 2 | `10s` | `10s` |
| 3 | `30s` | `40s` |
| 4 | `01:00` | `01:40` |
| 5 | `02:00` | `03:40` |
| 6 | `05:00` | `08:40` |
| 7 | `10:00` | `18:40` |
| 8 | `30:00` | `48:40` |
| 9 | `1:00:00` | `1:48:40` |
| 10 … 31 | `1:00:00` each | up to `24:00:00` |

After `24:00:00` of continuous failure the webhook enters state **`paused`**: no more
attempts, the cursor (`cursor_seq`) is kept, events keep accumulating in the log. Precisely:
after a failed attempt, if the next attempt would land more than `24:00:00` after the first
failure, the webhook pauses instead (attempt 31 is the last one on the table above). The owner
sees a paused webhook in the menu bar app and can resume it; the app can also resume itself
(`POST /v1/me/webhook/resume`) or replace the URL (`PUT /v1/me/webhook`). On resume, delivery
continues from the cursor with no events lost. While a webhook is `retrying` or `paused`, new
events queue behind the failing delivery; once it succeeds, the next batches drain the queue
at up to 100 events per delivery, back to back.

A gateway restart does not lose state: in-flight deliveries whose result is unknown are
retried (which is one source of duplicates).

### Guarantees

- **In order** per grant: a consumer never receives a `seq` lower than one it has already
  acknowledged with a `2xx`.
- **At least once**: a `2xx` that never reaches the gateway (network cut after the consumer
  processed the batch) results in the same delivery being sent again. Consumers dedupe on
  `seq` ([integrating.md](integrating.md#dedupe-on-seq)).
- **Never both**: a grant may use WebSocket and a webhook at the same time; they have
  independent cursors and the same events appear on both.

### Consumer-side pause

A consumer that wants the gateway to stop (maintenance, migration) answers `410 Gone`. The
gateway pauses immediately instead of retrying for a day; resume as above.

---

## Health

### `GET /v1/health`

Unauthenticated, no rate limit. Never reveals chat or grant data.

```json
{
  "status": "ok",
  "version": "0.1.0",
  "started_at": "2026-09-29T09:00:12.004Z",
  "time": "2026-09-29T14:03:37.001Z",
  "tdlib": {
    "auth_state": "ready",
    "connection_state": "ready"
  },
  "head_seq": 4812
}
```

| Field | Values |
|---|---|
| `status` | `ok` — logged in and connected. `degraded` — running, but `auth_state` or `connection_state` is not `ready`. |
| `tdlib.auth_state` | The Telegram login state: `wait_phone_number` (never logged in, or logged out), `wait_qr_confirmation` (a QR code is displayed and awaiting scan), `wait_code` (SMS/app code sent), `wait_password` (two-factor password needed), `ready` (logged in), `logging_out`, `closed`, `unknown`. |
| `tdlib.connection_state` | `waiting_for_network`, `connecting`, `updating` (connected, catching up on missed updates), `ready`. |

The HTTP status is `200` for `ok` and `degraded` alike (the endpoint answers "is the daemon
up"); use `status` for the rest.

### `GET /v1/admin/status`

Admin. Everything in `/v1/health` plus: `account` (`{ "user_id", "display_name", "username",
"phone_last4" }` when logged in), `monitored_chat_count`, `grant_count`,
`webhooks: { "active", "retrying", "paused" }` (counts), `events_last_hour`,
`oldest_seq`, `media_cache_bytes`, `backfill: { "in_progress": false, "chats_pending": 0 }`.

---

## Admin: login

The menu bar app drives the Telegram login through the daemon; `tgw` uses the same endpoints.
States are those in `tdlib.auth_state`.

| Method and path | Body | Effect |
|---|---|---|
| `GET /v1/admin/auth` | | `{ "auth_state": "wait_qr_confirmation", "qr_link": "tg://login?token=…", "phone_hint": null, "password_hint": null }`. `qr_link` is present only in `wait_qr_confirmation`; render it as a QR code for the owner to scan with a phone that is already logged in to Telegram. It changes every ~30s; poll this endpoint every 2s while displaying it. `password_hint` is set in `wait_password`. Every `POST` below answers with this same object (the state after the step). |
| `POST /v1/admin/auth/qr` | | Request (or refresh) a QR login. Moves to `wait_qr_confirmation`. |
| `POST /v1/admin/auth/phone` | `{ "phone_number": "+15551234567" }` | Fallback: start phone login. Moves to `wait_code`. |
| `POST /v1/admin/auth/code` | `{ "code": "12345" }` | Submit the code Telegram sent. Moves to `ready` or `wait_password`. |
| `POST /v1/admin/auth/password` | `{ "password": "…" }` | Submit the two-factor password. Moves to `ready`. A wrong password is `400 invalid_request` with `details.reason: "wrong_password"` and `details.password_hint`. |
| `POST /v1/admin/auth/logout` | | Ends the Telegram session on this device. The event log, grants and monitored set are kept; nothing new arrives until login. |

The daemon never stores phone number, code or password beyond passing them to TDLib. A wrong
code is `400 invalid_request` with `details.reason: "wrong_code"`. Without `api_id`/`api_hash`
configured, every login endpoint answers `503 not_logged_in` with `auth_state: "unknown"`.

---

## Admin: pruning

`POST /v1/admin/events/prune` with one of:

```json
{ "before_seq": 4000 }
```

```json
{ "older_than": "2026-06-01T00:00:00Z" }
```

Deletes events below the boundary. Refuses with `409` (`error.code: "cursor_behind"`,
`details.grant_id`) if any webhook cursor is behind the boundary, unless `"force": true`,
in which case that webhook will fail its next delivery with a gap (its cursor moves to the
new `oldest_seq`). Response `200 { "deleted": 3999, "oldest_seq": 4000 }`. Setting
`events_retention_days` in the configuration makes the daemon run the equivalent of
`older_than` once an hour.

---

## Rate limits

Limits are per token (per source address for unauthenticated endpoints) and generous, since
the API is local. They exist to protect Telegram's own limits (history and media are
proxied to Telegram) and the daemon's SQLite.

| Scope of limit | Limit |
|---|---|
| All requests, per token | 600 per minute |
| `GET /v1/chats/{chat_id}/messages` | 60 per minute (Telegram history reads) |
| `GET /v1/media/{media_id}` (uncached) | 4 concurrent downloads per token |
| `POST /v1/access-requests` | 10 per minute overall |
| `GET /v1/access-requests/{id}` | 1 per 2s per request id |
| WebSocket connections | 4 per token |

Exceeding a limit returns `429 rate_limited` with `Retry-After` (seconds) and
`details.retry_after`. Every authenticated response carries `X-RateLimit-Limit` and
`X-RateLimit-Remaining` for the per-token bucket (the unauthenticated endpoints have no
per-token bucket and carry neither).

---

## Endpoint index

| Auth | Method | Path | Scope | Purpose |
|---|---|---|---|---|
| none | GET | `/v1/health` | | Liveness and Telegram state |
| none | POST | `/v1/access-requests` | | Ask for access |
| none | GET | `/v1/access-requests/{id}` | | Poll for approval |
| app | GET | `/v1/me` | any | Own grant |
| app | GET | `/v1/me/webhook` | any | Webhook state |
| app | PUT | `/v1/me/webhook` | any | Set/replace webhook URL (new secret) |
| app | DELETE | `/v1/me/webhook` | any | Remove webhook |
| app | POST | `/v1/me/webhook/resume` | any | Resume a paused webhook |
| app | GET | `/v1/chats` | `chats:read` | Granted chats |
| app | GET | `/v1/chats/{chat_id}` | `chats:read` | One chat |
| app | GET | `/v1/events` | `messages:read` and/or `chats:read` | Paged backlog |
| app | GET | `/v1/events/stream` | `messages:read` and/or `chats:read` | WebSocket stream |
| app | GET | `/v1/chats/{chat_id}/messages` | `history:read` | Telegram history |
| app | GET, HEAD | `/v1/media/{media_id}` | `media:read` | File bytes |
| admin | GET | `/v1/admin/status` | | Full status |
| admin | GET | `/v1/admin/auth` | | Login state |
| admin | POST | `/v1/admin/auth/{qr,phone,code,password,logout}` | | Drive login |
| admin | GET | `/v1/admin/access-requests` | | Pending requests |
| admin | POST | `/v1/admin/access-requests/{id}/approve` | | Approve (narrowed) |
| admin | POST | `/v1/admin/access-requests/{id}/deny` | | Deny |
| admin | GET | `/v1/admin/grants` | | All grants |
| admin | GET | `/v1/admin/grants/{id}` | | One grant with stats |
| admin | DELETE | `/v1/admin/grants/{id}` | | Revoke |
| admin | POST | `/v1/admin/grants/{id}/webhook/resume` | | Resume a paused webhook |
| admin | GET | `/v1/admin/grants/{id}/deliveries` | | Delivery log |
| admin | GET | `/v1/admin/chats` | | Monitored chats, or `?all=true` for the account's chat list |
| admin | GET | `/v1/admin/folders` | | Chat folders |
| admin | GET, PUT | `/v1/admin/monitored-chats` | | The monitored set |
| admin | POST | `/v1/admin/events/prune` | | Delete old events |

"app" rows also accept the admin token, which behaves as a grant with every scope over every
monitored chat.

---

## Deviations and clarifications from the first draft

Recorded when the daemon was built (2026-09-29); each is also applied in the text above.

- **WebSocket authentication** cannot answer HTTP `401`: the channel drops any response that
  refuses an upgrade. The stream always upgrades and closes with `4401` (error frame first).
  Close codes `4400` (bad query) and `4429` (request budget) were added for the same reason.
- **`410 history_pruned`** fires when `since + 1 < oldest_seq`, never for `since = 0`.
- **Slow consumer** is measured as events behind the head of the log, not frames.
- **Webhook secret** is stored in plain text (the gateway signs with it). The **app token**
  is kept in plain text inside its access request for the `10:00` hand-out window, then erased.
- **`GET /v1/me/webhook`** without a webhook is `404 webhook_not_configured`; the other
  webhook operations use `409`. The admin token has no webhook (`409` on `PUT`).
- **`GET /v1/admin/auth`** also carries `password_hint`; every login `POST` returns this object.
- **Media**: unknown ids are `403 chat_not_granted`; a fifth concurrent uncached download per
  token is `429`; chat photos are reported as 640×640.
- **`PUT /v1/admin/monitored-chats`**: unknown folder → `400 invalid_request`; needs TDLib to
  validate chats (`503 not_logged_in` without a login); `stopped` before `started`.
- **Retention pause**: attempt 31 is the last; the pause happens when the next attempt would
  land past `24:00:00`.
- **`X-RateLimit-*`** headers appear on authenticated responses only.
- **History `has_more`** is "a full page came back".
