# Status

Updated: 2026-09-29

## Built

**Foundation** (build order step 1 in `docs/design.md`).

- `vendor/tdlib/build.sh` — builds `libtdjson.dylib` (TDLib 1.8.67, arm64, Release, OpenSSL
  linked statically, no Homebrew runtime dependency, macOS 15 deployment target) from the
  pinned commit. Idempotent. 01:43 for a clean build on an M5 Max.
- `CTDLib` — C module over `td_json_client.h`.
- `TDLibClient` — `actor TDLibClient`: one process-wide receive thread routing by
  `@client_id`; request/response correlation by `@extra`; `TDLibError`; `updates` stream;
  `AuthState` enum. Strict Swift 6 concurrency.
- `QRCode` — byte-mode QR encoder and terminal renderer.
- `tgw` direct commands — `login` (QR or `--phone`), `whoami`, `chats`, `watch`, `logout`.

**Daemon** (build order step 2). Everything below builds with `swift build`, passes
`swift test` (107 tests in 20 suites, 0.5s of test time, no account and no network needed) and the
daemon has been run against its own API with `curl` and `tgw` on a machine without
`api_id`/`api_hash`. Nothing has talked to Telegram yet.

- `GatewayCore` — the domain as a library: `Store` (GRDB, WAL, one migration, eleven tables),
  `EventLog` (append, exclusive `since`, `410` semantics, prune, per-process broadcast),
  `Grants` (tokens stored as SHA-256, `granted ∩ monitored` at read time, folder grants,
  scope gating, revocation broadcast, webhook settings), `AccessRequests` (device-code flow,
  `15:00` pending, `10:00` hand-out, purge), `Translator` (TDLib JSON → docs/events.md objects:
  every message content kind, entity subset with UTF-16 offsets, senders, forward origins,
  stable `med_` ids, edit dedupe, permanent deletes only, chat changes, folders, connection
  state), `Monitor` (monitored-set diffing with `monitoring.*` events, cursors, member-count
  coalescing, folder membership, backfill after a gap that survives live updates racing it),
  `WebhookDispatcher` (one loop per grant, ≤100 / 500 ms / 4 MiB batches, HMAC-SHA256, the
  retry ladder, pause after `24:00:00` or on `410`, resume, persisted cursors and deliveries,
  in-flight re-send after restart), `MediaCache` (download through TDLib, poll for completion,
  LRU eviction, index in the store), `RateLimiter`, `TelegramSession` (the daemon's TDLib
  owner: parameters, `online=false`, login steps, re-creates the client after `logOut`),
  `InstanceLock`, `Keychain`, `Config`, `Paths`, `JSONValue`, `GatewayClient`.
- `GatewayServer` — every route in docs/api.md's endpoint index on Hummingbird 2: the error
  JSON shape, `X-TGW-Request-Id`, per-token rate limits with `X-RateLimit-*` and `429`,
  access-request throttles, admin login endpoints, media with `Range` and `202` while
  downloading, the WebSocket stream with backlog, `caught_up`, heartbeat, all close codes, and
  `1001` on shutdown.
- `GatewayDaemon` — the executable: `TGW_HOME`/`config.json`/`TGW_PORT`, admin token in the
  Keychain on first run, lock file, stderr logging with `--verbose`, clean shutdown on
  SIGTERM/SIGINT (WebSockets `1001`, server drained, TDLib closed), hourly housekeeping and
  `events_retention_days`. Runs without credentials in a store-only mode.
- `tgw` daemon-backed commands — `daemon install|uninstall|status|logs` (LaunchAgent from
  `launchd/…plist`), `health`, `monitor list|add|remove|folders`, `requests
  list|approve|deny`, `grants list|show|revoke|resume-webhook`, `events tail|page`. The direct
  commands refuse to run while the daemon holds the lock.
- `GatewayTestSupport` — `FakeTDLib` (scripted from fixtures), `Fixtures` (TDLib objects with
  the field names in `td_api.tl`), `FakeWebhookClient`, `FakeTelegram`, `ManualClock`.
- Docs: `development.md` (daemon, launchd, data layout, every `tgw` command with output),
  `api.md` and `events.md` corrected where the implementation had to deviate (listed in
  the "Deviations" section of each).

## In progress

- First live login: add `api_id`/`api_hash` to `config.json`, `tgw daemon install`, then
  `tgw login` is not the path any more — log in through the daemon (`POST /v1/admin/auth/qr`
  and poll `GET /v1/admin/auth`, or the menu bar app once it exists). Until then everything
  TDLib-facing is exercised only through `FakeTDLib`.

## Next

- Verify against the real account (see "Needs a live account" below), then fix what TDLib
  does differently from the fixtures.
- Menu bar app (build order step 3): SMAppService registration, login UI over
  `/v1/admin/auth/*`, chat picker over `/v1/admin/chats?all=true`, approvals over
  `/v1/admin/access-requests`, activity over `/v1/admin/grants/{id}/deliveries`.
- First consumer (separate repository).

## Needs a live account to verify

Everything on the TDLib edge was written from the schema, not observed:

- Whether `updateNewMessage` arrives promptly for large channels the account has joined but
  never opened, and whether `loadChats` on the main list is needed before updates flow
  (`tgw watch` measures this; the daemon calls `loadChats` only when listing chats).
- The order of `updateMessageContent` and `updateMessageEdited` and whether `getMessage`
  already reflects the new `edit_date` when the first of them arrives (the translator
  emits once per `edit_date` either way).
- `getChatHistory` with `offset: -99` from the cursor: page shape and whether TDLib returns
  fewer than asked in the first call (the monitor loops until no newer message appears).
- Folder contents through `loadChats` + `getChats(chatListFolder)`; `updateChatAddedToList`
  / `updateChatRemovedFromList` for folder membership changes made on the phone.
- `member_count` on `supergroup` vs `supergroupFullInfo`, and how often
  `updateSupergroupFullInfo` fires (coalesced to one `chat.updated` per chat per `05:00`).
- `downloadFile(synchronous: false)` + `getFile` polling, the `local.path` TDLib reports, and
  whether `deleteFile` evicts cleanly.
- QR login through `requestQrCodeAuthentication` → `authorizationStateWaitOtherDeviceConfirmation`
  driven over HTTP, and the client re-creation after `logOut`.
- Update latency after the Mac sleeps and the connection returns (`connectionStateReady`
  triggers the backfill).

## Open questions

- The webhook secret is stored in plain text in `gateway.sqlite` because the gateway must
  sign with it; the token appears in `access_requests` for its `10:00` hand-out window and is
  then erased. Both could move under a Keychain-held key if the store's file protection
  (owner-only, in the home directory) is judged insufficient.
- `chat.updated` for a private chat's title/username follows `updateUser`; the gateway only
  re-reads the chat if it is monitored, so private chats cost nothing unless chosen.
- Whether to cap the WebSocket backlog replay speed; today it is bounded only by the socket.
