# Status

Updated: 2026-09-29

## Built

**Foundation** (build order step 1 in `docs/design.md`). Everything below builds with
`swift build`, passes `swift test` (29 tests, ~1s, no account needed) and has been exercised
against the real `libtdjson.dylib` with placeholder credentials up to the point where
Telegram would ask for a real `api_id`. A live login has not been done yet.

- `vendor/tdlib/build.sh` — builds `libtdjson.dylib` (TDLib 1.8.67, arm64, Release, OpenSSL
  linked statically, no Homebrew runtime dependency, macOS 15 deployment target) from the
  pinned commit. Idempotent. 01:43 for a clean build on an M5 Max.
- `CTDLib` — C module over `td_json_client.h`. Headers reach it through the committed symlink
  `Sources/CTDLib/include/td`; the dylib is found by absolute install name, no env vars.
- `TDLibClient` — `actor TDLibClient`: one process-wide receive thread routing by
  `@client_id`; request/response correlation by `@extra`; `TDLibError(code:message:)` for
  `error` objects; `updates` stream; `AuthState` enum (every `authorizationState*` in the
  pinned schema plus `unknown`) via `authState`, `authStates`, `waitForAuthState(where:)`,
  `nextAuthState(after:)`; `close()`; `TDLibParameters`. Strict Swift 6 concurrency.
- `QRCode` — byte-mode QR encoder, versions 1–40, all four error-correction levels, verified
  by tests that decode the rendered symbol with CoreImage. Terminal renderer (half-block
  and full-block).
- `tgw` — `login` (QR by default; `--phone` for code + password; email states handled),
  `whoami`, `chats [--limit]`, `watch <chat-id>... [--all]`, `logout`. Credentials from
  flags, `TGW_API_ID`/`TGW_API_HASH`, or `config.json`. Database key generated once and kept
  in the login Keychain. Every command closes TDLib cleanly on exit and on Ctrl-C. Sets
  `online=false` once ready; never calls `viewMessages`/`openChat`.
- `docs/development.md` — build, credentials, data locations, every command with output.

Gotchas hit while building (details in `docs/development.md` "Gotchas"): cmake 4 policy
minimum; SwiftPM refusing an umbrella header next to a directory (explicit module map
instead); install-name rewrite invalidating the ad-hoc signature (re-sign); ad-hoc-signed CLI
binaries triggering a Keychain prompt after each rebuild; `[String: Any]` not being
`Sendable` (returned as `sending`, boxed to cross threads).

## In progress

- First live login with the owner's `api_id`/`api_hash`: `tgw login`, then
  `tgw watch <channel-id>` to measure update latency for large channels.
- Contract documents: `docs/api.md`, `docs/events.md`, `docs/grants.md`, `docs/integrating.md`.

## Next

- Daemon: store, monitored chats, event log, backfill, WebSocket, webhooks, access requests.
- Menu bar app.
- First consumer (separate repo).

## Open questions

- Does TDLib deliver `updateNewMessage` promptly for large channels the account has joined
  but never opened? `tgw watch` prints receive time next to the message's own `date` so this
  can be measured once logged in.
- `tgw watch` calls `loadChats` on the main list before listening so TDLib knows every chat.
  Whether that is required for channel updates to flow, or whether TDLib pushes them
  regardless, is to be confirmed with the real account.
