# Menu bar app

The menu bar app (`App/`) is the owner's control panel for the gateway. It is a SwiftUI
application that lives only in the macOS menu bar (a paper-plane icon; no Dock icon, no
windows) and talks to the gateway daemon over the local HTTP API in [api.md](api.md) with the
admin token. It does four things:

1. **Setup**: stores the Telegram API credentials and starts the gateway daemon as a
   launchd LaunchAgent.
2. **Login**: drives the Telegram login (QR code first; phone number, code and two-step
   verification password as the fallback).
3. **Monitored chats**: picks which chats and folders the gateway watches.
4. **Access**: approves or denies applications' access requests, narrowing them to specific
   chats and scopes, and revokes grants.

A dot appears on the menu bar icon while an access request is waiting.

## Terms

- **Gateway daemon** (`GatewayDaemon`): the background process from [design.md](design.md)
  that holds the Telegram login and serves the API. The app never loads TDLib itself.
- **launchd**: the macOS service manager. A **LaunchAgent** is a launchd service that runs
  as the logged-in user; launchd starts it at login and restarts it if it exits.
- **`SMAppService`**: Apple's API (framework `ServiceManagement`) through which an app
  registers a LaunchAgent that ships inside its own bundle. Registered agents appear in
  System Settings → General → Login Items & Extensions, and macOS may ask the owner to
  allow them once.
- **Admin token**: the one token that may call `/v1/admin/*` (api.md "Authentication"). The
  daemon generates it on first run and writes it to the **secrets file**
  `~/Library/Application Support/TelegramGateway/secrets.json` (mode 0600, JSON
  `{"admin-token": "tgw_…"}`); the app reads it from there. The login Keychain (service
  `TelegramGateway`, account `admin-token`) is an opt-in alternative for a shipped,
  stably-signed build, selected with `"secrets": "keychain"` in `config.json`. Development
  builds must not use it: every ad-hoc-signed rebuild is a new identity to the Keychain, so
  each read would prompt the owner for their password. Tests and previews never touch it.
- **`api_id` / `api_hash`**: the identity of this software with Telegram, registered once at
  https://my.telegram.org ([development.md](development.md) "Register api_id / api_hash").
- **Popover**: the 360×520 panel that opens under the menu bar icon.

## Build and run

Requirements: Xcode 26 (Swift 6.3) and, for anything past the setup screen, a built daemon
(`swift build` in the repository root produces `.build/debug/GatewayDaemon`). XcodeGen is
not required: `App/TelegramGateway.xcodeproj` is checked in and builds from a clean checkout.
`App/project.yml` mirrors it for regenerating with `xcodegen generate` after structural
changes; keep both in sync.

```
# Build (Debug, ad-hoc signed):
xcodebuild -project App/TelegramGateway.xcodeproj -scheme TelegramGateway -configuration Debug build

# Build into App/.derived and launch (replaces a running copy):
App/run.sh

# Unit tests (28 tests: API decoding against api.md examples, login-link and QR handling,
# every flow over the fake gateway), ~1s:
App/run.sh --test
```

Or open `App/TelegramGateway.xcodeproj` in Xcode and press Run. Every screen has a preview
(`#Preview`) backed by `FakeAPIClient`, so the UI can be worked on without a daemon.

### Where things are

```
App/
  TelegramGateway.xcodeproj    Xcode project (synchronized folders: no file lists to maintain)
  project.yml                  XcodeGen mirror of the project
  run.sh                       build + launch, or --test
  Support/Info.plist           LSUIElement, TGWRepositoryRoot ($(SRCROOT)/.., development only)
  Support/gateway-launcher     the script launchd runs; finds and execs the daemon binary
  Support/LaunchAgents/com.brennancheung.telegram-gateway.daemon.plist   the LaunchAgent
  TelegramGateway/
    TelegramGatewayApp.swift   @main, MenuBarExtra (.window style), menu bar icon with badge
    API/                       APIClient protocol, HTTPAPIClient (URLSession), FakeAPIClient, models
    Services/                  GatewayConfig (config.json), AdminToken (secrets.json; Keychain opt-in), DaemonManager
                               (SMAppService + foreground child), QRCodeImage / LoginLink
    State/AppModel.swift       @Observable state; decides which screen from facts; polling
    Views/                     Setup, Login, Chats, Access (+ Approve), Status, Root/Header
    Debug/Snapshots.swift      `--snapshot` mode (Debug builds only), see "Checking the UI"
  TelegramGatewayTests/        Swift Testing suites
```

Bundle id `com.brennancheung.telegram-gateway`, macOS 15+, Swift 6 language mode with strict
concurrency, no third-party dependencies, ad-hoc code signature (`CODE_SIGN_IDENTITY = -`).
App Sandbox and Hardened Runtime are off: the app spawns `launchctl` and (in development) the
daemon, and reads a repository path.

### How the app finds the daemon binary

The daemon is not bundled yet. `DaemonLocator` tries, in order, and takes the first
existing executable:

1. `TGW_DAEMON_PATH` in the app's environment.
2. `daemon_path` in `~/Library/Application Support/TelegramGateway/config.json`.
3. `TGWRepositoryRoot` from the app's Info.plist (Xcode substitutes `$(SRCROOT)/..` at build
   time, so a build from this checkout knows where `.build/debug/GatewayDaemon` is).
4. Walking up from the app bundle's location to a directory containing `Package.swift`
   (`App/run.sh` builds into `App/.derived`, inside the repository).
5. `Contents/MacOS/GatewayDaemon` inside the app bundle — where a shipped build would carry it.

"Start gateway" writes the resolved path to `config.json` as `daemon_path` so the launcher
script (which launchd runs without the app's environment) finds the same binary.

**A shipped build** (TODO, not done): a build phase copies the release `GatewayDaemon` and
`libtdjson.dylib` into `Contents/MacOS/`, `gateway-launcher`'s last fallback already points
there, the daemon's `@rpath` must resolve to the bundled dylib, and the bundle is signed with a
Developer ID (at which point `"secrets": "keychain"` becomes usable without prompts). Until
then the app is a development tool that runs the daemon from the repository.

## The gateway as a LaunchAgent

The LaunchAgent plist is embedded at `TelegramGateway.app/Contents/Library/LaunchAgents/
com.brennancheung.telegram-gateway.daemon.plist`. Its `BundleProgram` is
`Contents/Resources/gateway-launcher`, a shell script that:

1. reads `daemon_path` from `config.json` (or `TGW_DAEMON_PATH`, or falls back to the bundle),
2. creates `~/Library/Logs/TelegramGateway/`,
3. `exec`s the daemon with stdout and stderr appended to `~/Library/Logs/TelegramGateway/daemon.log`.

launchd does not expand `~` in a plist, which is why the redirect happens in the script. The
script lives in `Contents/Resources` rather than `Contents/MacOS` because `codesign` refuses
an unsigned script in `MacOS` and the ad-hoc signature cannot sign a script as a code object.

`RunAtLoad` and `KeepAlive` are true: launchd starts the daemon as soon as the agent is
registered and again at every login, and restarts it if it exits (throttled to once every
10s; if the binary is missing the launcher sleeps 30s before exiting so the log stays quiet).
`ProcessType` is `Background`. `AssociatedBundleIdentifiers` names the app so Login Items
shows "Telegram Gateway" rather than the script.

What the app does with `SMAppService.agent(plistName:)`:

| Owner's action | App | launchd |
|---|---|---|
| **Start gateway** (Setup) | writes `daemon_path`, calls `register()` | loads the agent; runs the launcher now and at login |
| **Re-register** | same as above (after a rebuild or a moved bundle) | reloads |
| **Stop and unregister** | `unregister()` | stops the daemon, forgets the agent |
| **Restart gateway** (menu) | `launchctl kickstart -k gui/<uid>/com.brennancheung.telegram-gateway.daemon` | restarts the daemon |
| **Quit app** | quits | untouched: the gateway keeps running |

The app shows the `SMAppService` status in the Setup screen: *Not registered*, *Registered
with launchd (starts at login)*, *Waiting for approval in System Settings → Login Items*, or
*Registered, but launchd cannot find the agent (rebuild the app)* (`notFound`: the plist is
registered under a bundle path that no longer exists, for example after deleting
`App/.derived`; Re-register fixes it).

### The Login Items approval step

The first time an app registers a LaunchAgent, macOS may require the owner to allow it.
What the owner sees:

1. After clicking **Start gateway**, a system notification: *"Telegram Gateway" added items
   that can run in the background* (or the Setup screen shows *Waiting for approval…*).
2. The Setup screen offers **Open Login Items settings**. It opens System Settings → General
   → Login Items & Extensions.
3. Under **Allow in the Background**, the switch next to **Telegram Gateway** must be on.
   (Ad-hoc-signed development builds may show the app's name as the developer.)
4. Back in the popover, the status changes to *Registered with launchd* within a few seconds
   and *Waiting for the gateway at http://127.0.0.1:41414…* turns into the Login screen once
   the daemon answers `/v1/health`.

Approval persists until the app's bundle path or signature changes.

### Run in foreground (development fallback)

**Run in foreground** on the Setup screen spawns the daemon as a child process of the app
(stdout/stderr to `~/Library/Logs/TelegramGateway/daemon-foreground.log`). It is for
developing without launchd: the daemon dies when the app quits, so it never satisfies goal
#1 in [goal.md](goal.md). The button is disabled while the LaunchAgent is registered, because
two daemons on one TDLib directory corrupt it (design.md "Why one TDLib owner").

## Screens

The popover decides its screen from facts, in this order:

| Facts | Screen |
|---|---|
| `config.json` lacks valid `api_id`/`api_hash`, or `/v1/health` does not answer | **Setup** (credentials, then gateway control) |
| Daemon answers, `secrets.json` has no `admin-token` | **Admin token not found** with what to do |
| Daemon answers, `tdlib.auth_state` is not `ready` | **Login** |
| Logged in | **Status / Chats / Access** tabs |

The header always shows a dot (green: logged in and connected; orange: waiting; red: daemon
not reachable), a one-line summary, and the menu (⋯): Refresh, Restart gateway, Gateway
setup…, Open Login Items settings, Show gateway log, Log out of Telegram…, Quit app (with
the note that the gateway keeps running). There is no Pause/Resume monitoring entry because
the API has no such call; clearing the monitored set is the equivalent.

**Setup.** `api_id` and `api_hash` with a one-line explanation and a link to my.telegram.org.
Save merges them into `config.json`, keeping `port` and every other key. Then the gateway
section: the daemon binary found (or where it looked), the launchd status, Start gateway /
Open Login Items settings / Stop and unregister, Run in foreground.

**Login.** Reads `GET /v1/admin/auth` every 2s. If the state is `wait_phone_number` it calls
`POST /v1/admin/auth/qr` and renders `qr_link` as a QR code (CoreImage) with the
instructions *Open Telegram on your phone → Settings → Devices → Link Desktop Device*. The
image is redrawn only when the token in the link changes (they rotate every ~30s). *Use phone
number instead* switches to phone → code → password; a QR scan on an account with two-step
verification lands on the same password field, with the hint when the daemon provides one.
`wait_email_address` / `wait_email_code` are handled as text fields (see "Spec gaps"). When
`ready`, the header shows the account from `/v1/admin/status` and the menu offers Log out.

**Chats.** `GET /v1/admin/chats?all=true` (all pages), `GET /v1/admin/folders`,
`GET /v1/admin/monitored-chats`. Search field; Folders section and Chats section with
checkboxes (type icon, title, @username, member count). A chat covered by a ticked folder is
shown ticked and disabled. The footer shows the count that would be monitored after saving;
Save sends the whole set with `PUT /v1/admin/monitored-chats`; Revert discards.

**Access.** Pending requests (name, description, scopes, requested chats with monitored /
not monitored, webhook URL, expiry) with Deny and Approve…; grants (scopes, chats or folder,
webhook ok / retrying / paused with the last error, last seen) with Resume webhook when
paused and Revoke behind a confirmation. Refreshes every 5s while the tab is open; the
pending count is also polled in the background (every 15s while the popover is closed) for the
menu bar badge.

**Approve.** Chats mode lists the monitored chats with checkboxes, pre-ticked where the app
asked for them; requested chats that are not monitored are listed under *Requested but not
monitored* with *Monitor and include*, and approving then runs `PUT /v1/admin/monitored-chats`
before `POST …/approve`, so the owner makes one decision (grants.md). Folder mode offers the
monitored folders. Scopes are checkboxes limited to what was requested. The grant is
whatever the owner leaves ticked.

**Status.** Daemon reachable (host:port, version, up since, launchd state); Telegram login
and connection state; account; events in the last hour and total (`head_seq`); monitored
chat count; webhook counts; one line per grant with its last delivery (or last seen for
WebSocket-only grants).

## Checking the UI without clicking

Debug builds accept `--snapshot <directory>`: the app renders every screen with the fake
gateway into PNG files (light and dark) and quits. `--live` instead drives the real HTTP
client against whatever answers on the configured port through a scripted flow (QR → phone →
wrong code → code → wrong password → password → chats → save monitored → access → approve →
revoke → logout), printing each step and saving a PNG after each:

```
App/.derived/Build/Products/Debug/TelegramGateway.app/Contents/MacOS/TelegramGateway --snapshot /tmp/shots
TGW_HOME=/tmp/tgw-scratch …/TelegramGateway --snapshot /tmp/shots --live
```

`TGW_HOME` and `TGW_PORT` are honoured like the daemon honours them, so a scratch data
directory with its own `config.json` keeps a test away from the real one.

## Troubleshooting

**"Gateway not running" / Setup screen with "Waiting for the gateway…".** The app polls
`GET http://127.0.0.1:<port>/v1/health` and got no connection.
- Check the port: `port` in `~/Library/Application Support/TelegramGateway/config.json`
  (default 41414) must be what the daemon listens on; `TGW_PORT` in the app's environment
  overrides it for the app only.
- Check launchd: `launchctl print gui/$(id -u)/com.brennancheung.telegram-gateway.daemon`
  shows the state and last exit status. `state = not running` with a non-zero
  `last exit code` means the daemon is crashing on start; read
  `~/Library/Logs/TelegramGateway/daemon.log` (menu → Show gateway log).
- *"gateway-launcher: no daemon binary"* in the log: `.build/debug/GatewayDaemon` does not
  exist (run `swift build`) or `daemon_path` in `config.json` points somewhere stale. Fix and
  click Restart gateway (or Re-register).
- The Setup screen says *Registered, but launchd cannot find the agent*: the app bundle moved
  (for example `App/.derived` was deleted and rebuilt elsewhere). Click Re-register.

**"Admin token not found".** The daemon is up but
`~/Library/Application Support/TelegramGateway/secrets.json` has no `admin-token` entry (or
does not exist).
- The daemon writes it on its first start; if it just started, click Retry.
- The app and the daemon must use the same data directory: a daemon started with a custom
  `TGW_HOME` writes its `secrets.json` there, and the app reads `TGW_HOME` from its own
  environment (unset for an app launched from Finder or `open`).
- The error line names the problem when the file exists but is unreadable (not a JSON
  object, token not a string); fix or delete the file and Restart gateway to regenerate.
- *The gateway rejected the admin token* on the Status screen means the daemon regenerated
  it (e.g. `tgw` asked for a new one) after the app read it; Refresh re-reads the file.

**Keychain password prompts.** Only possible with `"secrets": "keychain"` in `config.json`,
which no development setup should have: the ad-hoc-signed app is a new "application" to the
Keychain after every rebuild, so each read prompts. Remove the key (or set `"file"`) and
restart the daemon so it writes `secrets.json`.

**QR code does not scan or "expired" on the phone.** The link rotates roughly every 30s and
the app redraws it within 2s of the daemon reporting a new one; keep the popover open while
scanning (closing it stops the 2s poll). If the phone says the code expired, click **New
code**. If nothing happens after a successful scan, the account probably has two-step
verification: the screen switches to the password field on its own; if it stays on the QR,
check `auth_state` in `GET /v1/admin/auth` — `wait_password` there but QR in the app means
the app is not polling (reopen the popover).

**Login Items denied / agent stuck on "Waiting for approval".** System Settings → General →
Login Items & Extensions → *Allow in the Background* → switch **Telegram Gateway** on. If it
is missing from the list, click Stop and unregister, then Start gateway again. A rebuild with
a different bundle path needs approval again. `sfltool resetbtm` (Apple's reset for the
background task manager) clears a wedged list; it requires a logout.

**Two daemons.** Never run `tgw` or Run in foreground while the LaunchAgent is running: TDLib
locks `td.binlog` and the second process fails or corrupts it. Stop and unregister first.

**Quitting the app does not stop the gateway.** That is by design (goal.md #1). To stop
the gateway: Setup → Stop and unregister, or `launchctl bootout
gui/$(id -u)/com.brennancheung.telegram-gateway.daemon`.

## What the app relies on beyond the first api.md

These were gaps when the app was written; the daemon and api.md now cover them, and the app
tolerates their absence where noted.

- Every login POST (`qr`, `phone`, `code`, `password`, `email`, `email_code`, `logout`)
  returns the `GET /v1/admin/auth` object. If a body does not decode as one, the app re-reads
  `GET /v1/admin/auth`.
- `GET /v1/admin/auth` carries `phone_hint` and `code_type` (`sms`, `call`,
  `telegram_message`, …) in `wait_code` and `password_hint` in `wait_password`; a wrong
  password is `400` with `error.details.reason = "wrong_password"` and
  `error.details.password_hint`.
- States `wait_email_address`, `wait_email_code` (endpoints `POST /v1/admin/auth/email
  { "email_address" }`, `POST /v1/admin/auth/email_code { "code" }`) and `wait_registration`
  (number with no account; the app explains and offers Start over).
- `/v1/admin/status.events_today` (optional in the app; the row is hidden when absent).
- `daemon_path` in `config.json` is tolerated by the daemon and listed in api.md.
- `secrets.json` holds `admin-token` base64-encoded (the app also accepts a raw `tgw_…`).
- There is no pause/resume-monitoring call, so the menu has no such entry.
- `requested_chats` in `GET /v1/admin/access-requests` is a list or the string `"any"`; the
  app decodes both.
