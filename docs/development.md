# Development

How to build and run the gateway on a Mac. Everything here is arm64 macOS only.

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
- **tgw** — the command-line tool in this repository, for development and administration.

## Prerequisites

| What | Where it comes from |
|---|---|
| Xcode 26 (Swift 6.3) | App Store / developer.apple.com |
| cmake, gperf | `brew install cmake gperf` |
| OpenSSL 3 | `brew install openssl@3` (only needed at build time; linked statically) |

The pinned toolchain and library versions are in `.tool-versions`-style form in
`vendor/tdlib/COMMIT` (TDLib) and `Package.swift` (Swift tools 6.0, macOS 15+).

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
swift build            # debug build, produces .build/debug/tgw
swift build -c release # .build/release/tgw
swift test             # unit tests, ~1s, no Telegram account needed
```

No environment variables are needed. The `CTDLib` target finds TDLib's headers through the
committed symlink `Sources/CTDLib/include/td` → `vendor/tdlib/include/td` and links the dylib
through an absolute `-L` derived from the package directory in `Package.swift`.

If `swift build` fails with `'td/telegram/td_json_client.h' file not found`, step 1 has not
run yet.

## 3. Register api_id / api_hash

1. Go to https://my.telegram.org, log in with your phone number.
2. Open "API development tools", create an application (any name; platform "Desktop").
3. Note the **App api_id** (number) and **App api_hash** (32 hex characters).

Give them to `tgw` in one of three ways, in this order of precedence:

1. Flags: `--api-id 12345 --api-hash 0123abcd…` on any command.
2. Environment: `TGW_API_ID=12345 TGW_API_HASH=0123abcd…`.
3. File: `~/Library/Application Support/TelegramGateway/config.json`
   ```json
   {"api_id": 12345, "api_hash": "0123abcd…"}
   ```

The file is the normal way on the owner's machine. Never commit these values, and never
reuse another application's pair.

## Where data lives

```
~/Library/Application Support/TelegramGateway/
  config.json      optional api_id / api_hash (see above)
  tdlib/           TDLib's directory: td.binlog, db.sqlite (encrypted), files/ (downloads)
```

The encryption key for `db.sqlite` is 32 random bytes generated on first run and stored in
the **login Keychain** as a generic password, service `TelegramGateway`, account
`tdlib-db-key`. Deleting that item makes the local database unreadable; `tgw logout` and
`tgw login` again is the recovery.

**Never run two processes on the same `tdlib/` directory.** TDLib locks `td.binlog`; a second
instance fails to start or corrupts the log. In practice: do not run `tgw` while the daemon
is running (stop the daemon first), and do not run two `tgw` commands at once.

## tgw commands

Every command opens TDLib, does its work, and closes TDLib cleanly (sends `close`, waits for
`authorizationStateClosed`) — including on Ctrl-C, which cancels the command and then closes.
A second Ctrl-C exits immediately. Every command accepts `--api-id` / `--api-hash`.

### `tgw login`

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
scan (some fonts leave gaps between half-blocks).

Fallback without a second device:

```
$ tgw login --phone +15551234567
Requesting a login code for +15551234567…
Code from Telegram (SMS or another device): 12345
Two-step verification password (hint: pet): 

Logged in as …
```

A wrong code or password is reported and asked again. A number with no account stops with
an error (this tool never creates accounts).

### `tgw whoami`

Resumes the saved login and prints the account.

```
$ tgw whoami
Brennan Cheung (@brennan) id=123456789 phone=+1555…
```

Without a saved login: `Error: not logged in (TDLib is at waitPhoneNumber); run `tgw login` first`.

### `tgw chats [--limit N]`

Loads the main chat list from Telegram (page by page until TDLib says there is nothing more)
and prints the first N (default 50), most recent first.

```
$ tgw chats --limit 5
id               type        unread  title
-1001234567890   channel         12  Swift Forums Digest
-1009876543210   supergroup       0  Volgenic Community
123456789        private          1  Alice
-987654321       basicGroup       0  Family
-1001111111111   channel        340  Industry News
```

Types: `private` (a user), `basicGroup` (small group), `supergroup` (large group),
`channel` (broadcast), `secret`. Negative ids are groups and channels; use them as-is.

### `tgw watch <chat-id>... [--all]`

Prints every new, edited and deleted message in the given chats as it arrives, one line each,
until Ctrl-C. `--all` watches every chat. It never marks anything as read (no `viewMessages`
or `openChat`) and sets the `online` option to false so the account does not appear online.

```
$ tgw watch -1001234567890
watching -1001234567890  channel  Swift Forums Digest
2026-09-29T15:02:11.482Z  date=2026-09-29T15:02:10Z (+1.5s)  chat=-1001234567890  msg=1234567  from=chat:-1001234567890  new  text  "SE-0501 accepted: …"
2026-09-29T15:03:40.010Z  date=-  chat=-1001234567890  msg=1234567  from=-  edited  text  "SE-0501 accepted (with revisions): …"
2026-09-29T15:04:02.777Z  date=-  chat=-1001234567890  msg=1234560  from=-  deleted  permanent
```

Columns: time received (UTC, ms), the message's own `date` from Telegram and the latency
between the two, chat id, message id, sender (`user:<id>` or `chat:<id>` for channel posts),
kind (`new` / `edited` / `deleted` / `deleted-from-cache`), content type, and the text or
caption (first 120 characters). `deleted-from-cache` means TDLib dropped the message from
its local cache, not that it was deleted on Telegram. The latency column answers the open
question in `docs/status.md` about how promptly TDLib delivers updates for large channels.

### `tgw logout`

Logs the account out on Telegram's side and lets TDLib delete its local database.

```
$ tgw logout
Logged out; local Telegram data removed from /Users/brennan/Library/Application Support/TelegramGateway/tdlib
```

## Layout of the code

```
Sources/CTDLib/        C module: module.modulemap + CTDLib.h including td_json_client.h
Sources/TDLibClient/   actor TDLibClient, AuthState, TDLibParameters, TDLibError, Receiver
Sources/QRCode/        QR encoder (byte mode, versions 1–40) and terminal rendering
Sources/tgw/           the CLI: Session (open / resume / close / Ctrl-C), Keychain, commands
Tests/                 swift-testing suites; no network, no account
```

`TDLibClient` is one actor per TDLib client. A single process-wide thread (`Receiver`) calls
`td_receive` in a loop — it is global across clients, so each object is routed by its
`@client_id` — and every request carries a unique `@extra` that TDLib echoes on the response,
which is how `send(_:)` returns the right answer. Updates (objects with no pending `@extra`)
go to `updates`; `updateAuthorizationState` is also decoded into `AuthState` and exposed as
`authState`, `authStates`, `waitForAuthState(where:)` and `nextAuthState(after:)`.

## Gotchas

- **cmake 4** removed support for `cmake_minimum_required` below 3.5; TDLib's tree is fine
  but `build.sh` passes `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` so sub-projects cannot break it.
- **Deployment target.** The dylib is built with `CMAKE_OSX_DEPLOYMENT_TARGET=15.0` to match
  `Package.swift`; without it the linker warns that the dylib was built for a newer macOS.
- **Signing.** Changing the install name invalidates the dylib's ad-hoc signature, and arm64
  macOS refuses to load unsigned code; `build.sh` re-signs (`codesign --sign -`).
- **Keychain prompts.** `tgw` is ad-hoc signed by `swift build`, so each rebuilt binary is a
  different "application" to the Keychain. Reading the key it stored earlier may show a
  "tgw wants to use your confidential information" dialog once per rebuild — click Always
  Allow. The daemon will be properly signed and will not have this problem.
- **SwiftPM header layout.** SwiftPM rejects an umbrella header with a directory next to it,
  which is why `Sources/CTDLib/include` carries an explicit `module.modulemap`.
- **`[String: Any]` under Swift 6.** JSON objects are not `Sendable`; the library returns
  them as `sending` values and wraps them in `JSONBox` (`@unchecked Sendable`) to cross
  threads. That is safe because `JSONSerialization` output is immutable.
- **TDLib is lazy.** A new client does nothing until it receives a request; `Session.open`
  sends `getOption version` so the first `authorizationState` arrives.
