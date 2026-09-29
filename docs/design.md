# Design

## The pieces

### 1. Gateway daemon (`GatewayDaemon`)

A background process started at login by a launchd **LaunchAgent** (runs as the owner's
user, not as a system daemon, so it can read the login Keychain). It is the only process
that loads TDLib. It:

- holds the Telegram login (TDLib's `td.binlog` and encrypted SQLite database)
- watches the monitored chats
- appends every new/edited/deleted message in a monitored chat to its own SQLite
  **event log**, with a monotonically increasing sequence number
- serves a local HTTP + WebSocket API on `127.0.0.1` (port in `docs/api.md`)
- delivers webhooks to consumers that asked for them

Data lives under `~/Library/Application Support/TelegramGateway/`:

```
tdlib/          TDLib's own directory (binlog, db.sqlite, files/). Never opened by anyone else.
gateway.sqlite  The gateway's store: monitored chats, grants, event log, delivery cursors.
```

TDLib's `database_encryption_key` is generated once and stored in the login Keychain.

### 2. Menu bar app (`App/`)

A SwiftUI menu bar app. It is a client of the daemon with admin rights (it authenticates with
an admin token the daemon writes to the Keychain on first run). It:

- registers the daemon with launchd via `SMAppService` (appears under System Settings →
  Login Items)
- shows login state and drives login (QR code first; phone/code/password fallback)
- lets the owner pick monitored chats from their chat list
- shows pending access requests and lets the owner approve (narrowed to specific chats),
  or revoke existing grants
- shows recent activity: events delivered per app, failing webhooks

### 3. One code base in Swift

TDLib's JSON interface is four C functions (`td_create_client_id`, `td_send`, `td_receive`,
`td_execute`). Swift calls them directly through a C module (`CTDLib`), so no bridge process
is needed. One toolchain, native Keychain, one bundle.

- HTTP/WebSocket: **Hummingbird**
- SQLite: **GRDB**
- TDLib wrapper: our own thin actor (`TDLibClient`), not a third-party binding. Third-party
  Swift bindings lag TDLib and pull in thousands of generated types we do not need.

### 4. TDLib built from source (`vendor/tdlib/`)

Homebrew ships TDLib 1.8.0 from 2021. We build `libtdjson.dylib` for arm64 from a **pinned
commit** (TDLib does not tag releases), with OpenSSL linked statically so the dylib has no
Homebrew dependency. `vendor/tdlib/build.sh` does it; the artifact is git-ignored and the
commit is recorded in `vendor/tdlib/COMMIT`.

The API ID / hash are our own, registered at https://my.telegram.org. Never reuse another
application's (e.g. Telegram Desktop's 2040) — that is a known way to get an account flagged.

## Why one TDLib owner

| Part of TDLib's directory | Shareable? |
|---|---|
| `td.binlog` | **No.** Locked by the running instance; a second instance fails or corrupts it. |
| `db.sqlite` | **Not usefully.** Encrypted once a key is set, and rows are TDLib's internal binary serialization, undocumented and version-dependent. |
| `files/` | Yes, read-only. Plain downloaded files. |

So the daemon owns TDLib and everything else goes through the API. Media is exposed to
consumers as gateway URLs, not filesystem paths, so consumers on other machines work the
same way.

## Access model

- **Monitored chats**: the set the gateway watches and stores. Chosen by the owner.
  Everything else (DMs, unmonitored groups) never leaves the gateway.
- **Grant**: one application × a set of scopes × a set of monitored chats (or a Telegram
  folder, so adding a channel to the folder on the phone extends access automatically).
- **Scopes** (full detail in `docs/grants.md`):
  `messages:read`, `history:read`, `media:read`, `chats:read`, and the reserved
  `messages:send` (not implemented in v1).
- **Flow**: the application calls `POST /v1/access-requests` → owner approves in the menu
  bar app → the application, polling, receives its token. Device-code style, no browser.

## Delivery

- **Our own event format** (`docs/events.md`): `message.new`, `message.edited`,
  `message.deleted`, `chat.updated`. TDLib JSON never reaches consumers.
- **Sequence numbers.** Every event is appended to the log before delivery. A consumer
  resumes with `since=<seq>`.
- **WebSocket**: connect with `since`, receive the backlog, then stay live.
- **Webhooks**: delivered in order from the same log, signed (HMAC-SHA256), retried with
  backoff; the gateway tracks each consumer's cursor.
- **Backfill after gaps.** TDLib may not replay every missed message in a busy channel after
  a long disconnect. For each monitored chat the gateway stores the last message id it has
  seen and, on reconnect, pulls `getChatHistory` from that id forward. Nothing is lost;
  at worst it is late.
- **Do not disturb.** The gateway never calls `viewMessages`/`openChat` in a way that marks
  as read, and never sets the account online.

## Build order

1. **Foundation**: TDLib build, `CTDLib`, `TDLibClient`, `tgw login` (QR + phone) and
   `tgw watch <chat…>` printing new messages. Proves behaviour with the real account.
2. **Daemon**: store, monitored chats, event log, backfill, WebSocket, webhooks, access
   requests, tokens. Administered via `tgw` before there is a UI.
3. **Menu bar app**: login, chat picker, access approvals, activity.
4. **First consumer** (separate repo): classification + sentiment + counts with Jev.

## Decisions taken

- Swift for everything, including the daemon. (Owner said backend language is free.)
- Read-only in v1. `messages:send` reserved.
- Local API + outbound webhooks in v1. Remote WebSocket consumers would need Tailscale or
  similar and are deferred.
- Not part of Volgenic. Standalone repository, no Volgenic work items.
