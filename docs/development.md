# Development

How to build and run the gateway on a Mac. Everything here is arm64 macOS only. Durations
are written `mm:ss` (or `h:mm:ss`); values under a minute as seconds.

## Terms

- **TDLib** — Telegram's official client library (C++). It speaks Telegram's protocol, keeps
  the login and a local cache of chats and messages, and exposes a JSON interface of four
  C functions (`td_create_client_id`, `td_send`, `td_receive`, `td_execute`). We build it from
  source as `libtdjson.dylib`.
- **api_id / api_hash** — the identity of *this application* with Telegram (a number and a
  hex string). Every Telegram client program has its own pair; it is not tied to an account.
  Registered once at https://my.telegram.org.
- **binlog** — `td.binlog`, TDLib's append-only log in its data directory. It holds the
  login session and everything TDLib must not lose. Only one process may have it open.
- **daemon** — `GatewayDaemon`, the background process that owns TDLib, records events and
  serves the local API (docs/api.md). launchd keeps it running.
- **tgw** — the command-line tool in this repository. Its daemon-backed commands administer
  the running daemon over the API; its direct commands open TDLib themselves (development
  before the daemon is installed) and refuse to run while the daemon is up.
- **TGW_HOME** — the data directory, `~/Library/Application Support/TelegramGateway` unless
  the environment variable says otherwise.

## Prerequisites

| What | Where it comes from |
|---|---|
| Xcode 26 (Swift 6.3) | App Store / developer.apple.com |
| cmake, gperf | `brew install cmake gperf` |
| OpenSSL 3 | `brew install openssl@3` (only needed at build time; linked statically) |

The pinned toolchain and library versions are in `vendor/tdlib/COMMIT` (TDLib) and
`Package.swift` (Swift tools 6.0, macOS 15+). Swift package dependencies: Hummingbird 2
(HTTP + WebSocket), GRDB 7 (SQLite), swift-argument-parser, swift-log, swift-service-lifecycle.

## 1. Build TDLib

```
./vendor/tdlib/build.sh
```

This clones `tdlib/td` at the commit in `vendor/tdlib/COMMIT` into `vendor/tdlib/src`,
configures a Release build for arm64 into `vendor/tdlib/build`, builds only the `tdjson`
target, installs into `vendor/tdlib/lib` and `vendor/tdlib/include`, and prints the absolute
path of the dylib on its last line. All four directories are git-ignored.

- OpenSSL is linked statically (`OPENSSL_USE_STATIC_LIBS=TRUE`), so the dylib depends only on
  `/usr/lib` (`libz`, `libc++`, `libSystem`). The script checks this with `otool -L` and fails
  if anything under `/opt/homebrew` is referenced.
- The dylib's install name is set to its absolute path, so binaries built by `swift build`
  find it without `DYLD_LIBRARY_PATH`. Moving the repository means re-running the script.
- Re-running is cheap: an existing checkout at the right commit and an existing build tree are
  reused. Delete `vendor/tdlib/build` to rebuild, `vendor/tdlib/src` to re-clone.
- `-j18` by default (`JOBS=8 ./vendor/tdlib/build.sh` to change).

Measured on an Apple M5 Max (18 cores), clean build, TDLib 1.8.67 at the pinned commit:

| Run | Wall time | Notes |
|---|---|---|
| First (clone + configure + build + install) | 01:43 | user CPU 18:40 across 18 cores |
| Clean rebuild (build tree deleted) | 01:45 | |
| Re-run with everything present | 2s | install + link check only |

## 2. Build the Swift package

```
swift build            # debug build: .build/debug/GatewayDaemon and .build/debug/tgw
swift build -c release # .build/release/…
swift test             # unit tests, no Telegram account or network needed
```

No environment variables are needed. The `CTDLib` target finds TDLib's headers through the
committed symlink `Sources/CTDLib/include/td` → `vendor/tdlib/include/td` and links the dylib
through an absolute `-L` derived from the package directory in `Package.swift`.

If `swift build` fails with `'td/telegram/td_json_client.h' file not found`, step 1 has not
run yet. The first `swift build` also fetches and compiles the Swift dependencies (Hummingbird,
GRDB, NIO): about 03:00 on an M5 Max; incremental builds are seconds.

Tests (`swift test`) take about 13s wall once built (the tests themselves run in 0.5s): 108 tests in 21 suites, all without an
account. They cover the store and migrations, the event log (paging, prune, `410`), grants
(intersection with the monitored set, scope gating, revocation), access requests (expiry,
approval, purge), the translator (a fixture per event type, hand-written from the TDLib
schema), the monitor (monitoring events, member-count coalescing, folders, backfill after a
gap), webhook delivery (batching, signature, the retry ladder and the `24:00:00` pause with a
fake clock and fake HTTP), the media cache (download, LRU eviction), and every HTTP route and
WebSocket close code through Hummingbird's in-process test client.

## 3. Register api_id / api_hash

1. Go to https://my.telegram.org, log in with your phone number.
2. Open "API development tools", create an application (any name; platform "Desktop").
3. Note the **App api_id** (number) and **App api_hash** (32 hex characters).

Put them in `<TGW_HOME>/config.json`:

```json
{"api_id": 12345, "api_hash": "0123abcd…"}
```

That file is read by the daemon and by `tgw`. The direct `tgw` commands also accept
`--api-id` / `--api-hash` flags and `TGW_API_ID` / `TGW_API_HASH` in the environment (flags
win, then environment, then the file). The daemon reads the file (and the environment
variables) at startup; without a pair it still runs, serving the store-backed API, and logs
that Telegram is disabled. Never commit these values, and never reuse another application's
pair.

## Where data lives

```
~/Library/Application Support/TelegramGateway/     (TGW_HOME overrides)
  config.json      port, events_retention_days, media_cache_max_bytes, api_id, api_hash
  gateway.sqlite   the gateway's store (WAL mode): monitored set, chats and folders cache,
                   event log, per-chat cursors, access requests, grants, deliveries, media index
  tdlib/           TDLib's directory: td.binlog, db.sqlite (encrypted), files/ (downloads)
  logs/            daemon.out.log, daemon.err.log when run by launchd
  daemon.lock      flock held by the process that owns TDLib (the daemon, or a direct tgw command)
  secrets.json     TDLib database key and admin token (file secret store, mode 0600)
```

`config.json` (all keys optional):

```json
{
  "port": 41414,
  "events_retention_days": null,
  "media_cache_max_bytes": 2147483648,
  "secrets": "file",
  "api_id": 12345,
  "api_hash": "0123abcd…"
}
```

`TGW_PORT` overrides `port` for one process; `TGW_HOME` moves the whole directory (used to
run a second, isolated gateway in development).

### Secrets: file store in development, Keychain in the shipped app, why

The gateway has two secrets:

| Key | Holds | Created by |
|---|---|---|
| `tdlib-db-key` | 32 random bytes TDLib encrypts `db.sqlite` with. Deleting it makes the local database unreadable; log in again is the recovery. | whichever process opens TDLib first |
| `admin-token` | The admin token (`tgw_…`) the daemon accepts for `/v1/admin/*` and that `tgw` sends. | the daemon, on first run |

They live in a **secret store** (`SecretStore` in GatewayCore) chosen by `config.json`:

- `"secrets": "file"` (the default): `<TGW_HOME>/secrets.json`, `{ "<key>": "<base64>" }`,
  mode `0600`, written atomically. Every `swift build` binary — `tgw`, `GatewayDaemon` —
  uses this.
- `"secrets": "keychain"`: generic passwords in the login Keychain, service
  `TelegramGateway`, accounts as above. Only for the shipped menu bar app and the daemon it
  bundles, which are signed with a stable identity.

Why the split: macOS ties a Keychain item to the signing identity of the app that created
it, and an ad-hoc-signed binary (what `swift build` produces) gets a new identity on every
rebuild. Each read from a "new" app shows the owner a password prompt, so development
builds and tests would prompt on every rebuild — which is exactly what happened before the
file store existed. Rules that follow:

- **Tests never call the Keychain.** They use `MemorySecretStore` (or a `FileSecretStore`
  in a temporary directory).
- **Development binaries never read the Keychain unless `config.json` says so.** Leave
  `secrets` unset while developing.
- `tgw secrets` shows which store is active and which keys exist (never the values);
  `tgw secrets regenerate-admin-token` replaces the token; `tgw secrets import-keychain`
  copies items an earlier build left in the Keychain into the file store — it is the one
  command that does read the Keychain, so expect a prompt, and run it only if you want to
  keep that login rather than logging in again.

**One TDLib owner.** TDLib locks `td.binlog`; a second instance fails to start or corrupts
the log. `daemon.lock` enforces this: the daemon holds it while running, a direct `tgw`
command holds it while it runs, and whoever finds it held refuses to start with a message
naming the holder and what to do instead.

## Running the daemon

In a terminal, for development:

```
$ swift build
$ .build/debug/GatewayDaemon --verbose
2026-09-29T21:04:19-0700 info daemon: Telegram Gateway 0.1.0 listening on http://127.0.0.1:41414, data in /Users/you/Library/Application Support/TelegramGateway
2026-09-29T21:04:19-0700 info http: Server started and listening on 127.0.0.1:41414
```

| Flag | Meaning |
|---|---|
| `--verbose` | Debug-level logging (every request, every delivery attempt). Default is info. |
| `--home <dir>` | Data directory (same as `TGW_HOME`). |
| `--port <n>` | Port (same as `TGW_PORT`; both override `config.json`). |

Logs go to stderr. Ctrl-C or SIGTERM stops it cleanly: open WebSockets get close code
`1001`, the HTTP server drains, TDLib receives `close` and the daemon waits for `closed` so
the binlog is flushed. On first run it generates the admin token into the secret store
(`secrets.json` unless configured otherwise).

What the daemon does once up: answers `waitTdlibParameters`, sets `online = false` when the
login is ready, consumes TDLib updates through the translator into the event log for chats
in the monitored set, keeps a per-chat cursor and backfills with `getChatHistory` when the
connection comes back after a gap (also at startup), refreshes the folder cache on
`updateChatFolders`, runs one delivery loop per webhook, sweeps expired access requests and
applies `events_retention_days` once an hour.

A second gateway for experiments:

```
TGW_HOME=/tmp/tgw-dev TGW_PORT=41499 .build/debug/GatewayDaemon --verbose
```

### Without credentials

With no `api_id`/`api_hash` the daemon starts anyway: `GET /v1/health` reports
`auth_state: unknown`, the events, grants and access-request endpoints work from the store,
and anything that needs Telegram (login endpoints, history, media, monitoring a chat the
cache has never seen, the chat list) answers `503 not_logged_in`.

## launchd

`tgw daemon install` writes `~/Library/LaunchAgents/com.brennancheung.telegram-gateway.plist`
from the template in `launchd/` (with the daemon binary, `TGW_HOME` and the log paths
resolved) and bootstraps it into the user's launchd domain. `RunAtLoad` and `KeepAlive` are
set: the daemon starts at login and is restarted if it exits. It runs as the owner's user (a
LaunchAgent, not a system daemon), which is what lets it read the login Keychain.

```
$ swift build -c release
$ .build/release/tgw daemon install
installed /Users/you/Library/LaunchAgents/com.brennancheung.telegram-gateway.plist
binary    /Users/you/code/telegram-gateway/.build/release/GatewayDaemon
data      /Users/you/Library/Application Support/TelegramGateway
logs      /Users/you/Library/Application Support/TelegramGateway/logs/daemon.err.log
The daemon starts now and at every login. `tgw health` to check it.

$ tgw daemon status
plist     /Users/you/Library/LaunchAgents/com.brennancheung.telegram-gateway.plist
launchd   state = running, pid = 61192
lock      held by pid 61192 (daemon)
health    degraded auth=wait_phone_number head_seq=0 on port 41414

$ tgw daemon logs -n 50        # -f to follow
$ tgw daemon uninstall         # bootout + remove the plist; data is kept
```

The binary path is resolved when you install: `GatewayDaemon` next to the `tgw` you ran, or
`--binary <path>`. Rebuilding in place is fine (launchd restarts on exit); moving the binary
means `tgw daemon install` again. The menu bar app will later register the daemon with
`SMAppService` (System Settings → Login Items) and this command will step aside.

## tgw commands

Two families. The **daemon-backed** commands talk to the running daemon over the API with the
admin token from the Keychain and never touch TDLib. The **direct** commands open TDLib
themselves (the foundation's development tools) and refuse to run while the daemon holds
`daemon.lock`, pointing at the daemon-backed equivalent. Every daemon-backed command accepts
`--json` to print the daemon's reply instead of a table.

### `tgw health`

```
$ tgw health
status        ok   version 0.1.0   port 41414
telegram      auth=ready  connection=ready
account       Brennan Cheung (@brennan) id=123456789 phone=…4567
events        head_seq=4812  oldest_seq=1  last_hour=37
monitored     2 chats   grants 1   webhooks active=1 retrying=0 paused=0
backfill      in_progress=false chats_pending=0   media_cache=184320 bytes
started       2026-09-29T09:00:12.004Z
```

Without an admin token in the Keychain it prints the unauthenticated `/v1/health` part only.

### `tgw monitor`

```
$ tgw monitor list --all          # every chat in the account (needs a logged-in daemon)
id               type        monitored  title
-1001234567890   channel     yes        Acme Product Updates
-1009876543210   supergroup             Acme Community
123456789        private                Ada Lovelace

$ tgw monitor add -1009876543210 folder:3
chat_ids       -1001234567890,-1009876543210
folder_ids     3
effective      3 chats
id               type        members  title
-1009876543210   supergroup  4200     Acme Community
-1001987654321   channel     880      Acme Support
-1001234567890   channel     12840    Acme Product Updates

$ tgw monitor remove folder:3
$ tgw monitor folders
id  monitored  chats  title
3              2      Product
```

`add`/`remove` read the current set, change it, and `PUT /v1/admin/monitored-chats` the
result. Each chat entering or leaving the effective set produces a `monitoring.started` /
`monitoring.stopped` event.

### `tgw requests`

```
$ tgw requests
req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP   pending   expires 2026-09-29T14:18:07Z
  Community Analytics — Classifies messages in product channels and counts topics per day.
  scopes: chats:read history:read messages:read
  chat -1001234567890  Acme Product Updates  monitored
  chat -1001987654321  (unknown)  NOT monitored
  webhook: https://analytics.example.com/tgw/events

$ tgw requests approve req_7Hs2… --chats -1001234567890 --scopes messages:read chats:read
approved: grant grant_Ab3dE5fG7hJ9kL1m for Community Analytics
scopes    chats:read messages:read
effective -1001234567890
The app receives its token on its next poll (within 10:00).

$ tgw requests approve req_… --folder 3
$ tgw requests deny req_… --reason "Not now."
$ tgw requests list --all
```

### `tgw grants`

```
$ tgw grants
id                      app                  scopes                    chats     effective  webhook             last seen             revoked
grant_Ab3dE5fG7hJ9kL1m  Community Analytics  chats:read,messages:read  1 chats   1          active (0 pending)  2026-09-29T14:07:12Z  -

$ tgw grants show grant_Ab3dE5fG7hJ9kL1m     # the grant object, stats, recent deliveries
$ tgw grants revoke grant_Ab3dE5fG7hJ9kL1m
revoked grant_Ab3dE5fG7hJ9kL1m
$ tgw grants resume-webhook grant_…
```

### `tgw events`

```
$ tgw events tail --since 4800
4801  2026-09-29T14:03:07Z  message.new  -1001234567890 "Acme Product Updates"  msg=412 from=Acme Product Updates [photo] v2.4 is out.
4802  2026-09-29T14:05:02Z  message.edited  -1009876543210 "Acme Community"  msg=1523 from=Ada Lovelace @acmebot the export …
caught up at seq 4812; live
4813  2026-09-29T14:06:41.900Z  message.deleted  -1009876543210 "Acme Community"  ids=1520,1521
```

`tail` holds the WebSocket with the admin token (so it sees every monitored chat); `--since`
replays first, `--types` and `--chat` filter, `--json` prints raw frames. `tgw events page
--since N --limit M` fetches one page over HTTP.

### Direct TDLib commands: `tgw login`, `whoami`, `chats`, `watch`, `logout`

Every direct command opens TDLib, does its work, and closes TDLib cleanly (sends `close`,
waits for `authorizationStateClosed`) — including on Ctrl-C, which cancels the command and
then closes. A second Ctrl-C exits immediately. While the daemon is running they stop at
once:

```
$ tgw whoami
Error: the gateway daemon (pid 61192) is running and owns TDLib. Direct TDLib commands cannot run at the same time; use the daemon-backed equivalents (`tgw health`, `tgw monitor`, `tgw requests`, `tgw grants`, `tgw events tail`) or stop the daemon first (…)
```

Logging in for the daemon is done through the daemon (`POST /v1/admin/auth/*`, the menu bar
app later); a login made with `tgw login` while the daemon is stopped is picked up by the
daemon on its next start, since both use the same `tdlib/` directory and Keychain key.

#### `tgw login`

Logs in. Default is QR: the terminal shows a QR code for the `tg://login?token=…` link and
the link itself. On the phone: Telegram → Settings → Devices → Link Desktop Device, scan.
If the account has two-step verification, the password is asked next (typed without echo).
The code refreshes itself when the token expires.

```
$ tgw login

Scan this with Telegram on your phone: Settings → Devices → Link Desktop Device

▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
█ ▄▄▄▄▄ █▀ █▄▀▄▀▄██ ▄▄▄▄▄ █
…

Link: tg://login?token=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA
Waiting for confirmation… (Ctrl-C to abort)
Two-step verification password (hint: pet): 

Logged in as Brennan Cheung (@brennan) id=123456789 phone=+1555…
Data: /Users/brennan/Library/Application Support/TelegramGateway/tdlib
```

`--large-qr` draws each module as two full characters if the half-block rendering does not
scan. `--phone +15551234567` uses the code + password flow instead of QR. A wrong code or
password is reported and asked again. A number with no account stops with an error (this
tool never creates accounts).

#### `tgw whoami`, `tgw chats [--limit N]`, `tgw watch <chat-id>... [--all]`, `tgw logout`

`whoami` resumes the saved login and prints the account. `chats` loads the main chat list and
prints the first N (default 50), most recent first, as `id type unread title`. `watch` prints
every new, edited and deleted message in the given chats as it arrives (one line each: time
received, the message's own date and the latency between them, chat, message id, sender,
kind, content type, text) until Ctrl-C; it never marks anything as read and keeps the
account offline. `logout` logs the account out on Telegram's side and lets TDLib delete its
local database.

## Layout of the code

```
Sources/CTDLib/            C module: module.modulemap + CTDLib.h including td_json_client.h
Sources/TDLibClient/       actor TDLibClient, AuthState, TDLibParameters, TDLibError, Receiver
Sources/QRCode/            QR encoder (byte mode, versions 1–40) and terminal rendering
Sources/GatewayCore/       the domain, testable without an account:
  Paths, Config, SecretStore (file / Keychain / memory), Keychain, InstanceLock, Identifiers, Clock (System/Manual), JSONValue, Models
  Store (GRDB, migrations), EventLog, Grants, AccessRequests, APIError
  TDLibRequesting (the protocol TDLib hides behind), Translator (TDLib JSON → events.md objects)
  Monitor (updates → log, cursors, backfill, folders), WebhookDispatcher, MediaCache, RateLimiter
  TelegramSession (the daemon's TDLib owner; NoTelegram when no credentials), Maintenance, GatewayClient
Sources/GatewayServer/     Hummingbird routes for docs/api.md: Context, Middleware, AppRoutes, AdminRoutes, EventStream
Sources/GatewayDaemon/     main.swift: wiring, lock, signals, housekeeping
Sources/GatewayTestSupport/ FakeTDLib, Fixtures (TDLib objects per td_api.tl), FakeWebhookClient, FakeTelegram
Sources/tgw/               the CLI: Session (direct TDLib), Admin (daemon client), Commands/
Tests/                     swift-testing suites; no network, no account
launchd/                   the LaunchAgent plist template
```

`TDLibClient` is one actor per TDLib client. A single process-wide thread (`Receiver`) calls
`td_receive` in a loop — it is global across clients, so each object is routed by its
`@client_id` — and every request carries a unique `@extra` that TDLib echoes on the response,
which is how `send(_:)` returns the right answer. Updates (objects with no pending `@extra`)
go to `updates`; `updateAuthorizationState` is also decoded into `AuthState`.

Everything above `TDLibClient` talks to TDLib through the one-method `TDLibRequesting`
protocol, so tests substitute `FakeTDLib`, which answers `getUser`, `getChat`,
`getSupergroup`, `getMessage`, `getChatHistory`, `getRemoteFile`, `downloadFile`… from
fixtures written by hand from `vendor/tdlib/src/td/generate/scheme/td_api.tl`. Time goes
through `GatewayClock` so `ManualClock` drives expiries, batching delays and the webhook
retry ladder in tests without waiting.

## Gotchas

- **cmake 4** removed support for `cmake_minimum_required` below 3.5; TDLib's tree is fine
  but `build.sh` passes `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` so sub-projects cannot break it.
- **Deployment target.** The dylib is built with `CMAKE_OSX_DEPLOYMENT_TARGET=15.0` to match
  `Package.swift`; without it the linker warns that the dylib was built for a newer macOS.
- **Signing.** Changing the install name invalidates the dylib's ad-hoc signature, and arm64
  macOS refuses to load unsigned code; `build.sh` re-signs (`codesign --sign -`).
- **Keychain prompts.** `tgw` and `GatewayDaemon` are ad-hoc signed by `swift build`, so each
  rebuilt binary is a different "application" to the Keychain, and the two binaries are
  different applications from each other. Reading an item another build created shows a
  "wants to use your confidential information" dialog. That is why secrets live in
  `secrets.json` in development (see "Secrets" above) and only the signed app opts into
  the Keychain. `tgw secrets import-keychain` is the one development command that reads it.
- **SwiftPM header layout.** SwiftPM rejects an umbrella header with a directory next to it,
  which is why `Sources/CTDLib/include` carries an explicit `module.modulemap`.
- **`[String: Any]` under Swift 6.** JSON objects are not `Sendable`; the library returns
  them as `sending` values and wraps them in `JSONBox` (`@unchecked Sendable`) to cross
  threads. That is safe because `JSONSerialization` output is immutable. Nothing `Any`-typed
  leaves `Translator`; the API layer works in `JSONValue`, a typed tree that keeps key order
  and writes explicit `null`s.
- **TDLib is lazy.** A new client does nothing until it receives a request; the daemon and
  `Session.open` send `getOption version` so the first `authorizationState` arrives.
- **Message ids.** TDLib's `message.id` is the public id shifted left by 20 bits (docs/api.md
  "Message ids"). Cursors in `chat_cursors` are internal ids; everything on the API is public.
  A supergroup with id S is chat `-1000000000000 - S`; a basic group B is chat `-B`.
- **WebSocket refusals cannot carry a body.** When the router refuses an upgrade, the
  WebSocket channel drops the response and the client sees a bare 400/307. So
  `/v1/events/stream` always upgrades and reports authentication failures with an error frame
  and close code `4401` (docs/api.md "Close codes").
- **`WebSocketInboundStream` allows one iterator.** In tests, make one
  `inbound.messages(maxSize:).makeAsyncIterator()` per connection and pass it around.
- **GRDB inside an actor.** `Store` is an actor over a `DatabaseQueue`; its synchronous
  `read`/`write` calls block that actor's thread for the few milliseconds a statement takes,
  which is fine at this scale. WAL mode is set in `prepareDatabase`.
- **swift-testing output and hangs.** A test that never returns (an un-cancellable task in a
  task group, say) stalls the whole `swift test` run silently. Run one suite with
  `swift test --filter GatewayCoreTests.MonitorTests` to find it.
