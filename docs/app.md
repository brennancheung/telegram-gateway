# Menu bar app

The menu bar app (`App/`) is the owner's control panel for the gateway. It is a SwiftUI
application that lives only in the macOS menu bar (a paper-plane icon; no Dock icon, no
windows) and talks to the gateway daemon over the local HTTP API in [api.md](api.md) with the
admin token. It takes the owner through three setup steps and then shows three tabs:

1. **Connect**: stores the Telegram key and starts the gateway.
2. **Sign in**: the Telegram login (QR code first; phone number, code and two-step
   verification password as the fallback).
3. **Choose chats**: which chats and folders the gateway monitors.

Afterwards: **Overview** (is it working, does anything need me), **Chats** (the monitored
set) and **Apps** (approve or deny applications' access requests, narrow them to specific
chats and permissions, revoke access).

A dot appears on the menu bar icon while an access request is waiting.

## Terms

- **Gateway daemon** (`GatewayDaemon`): the background process from [design.md](design.md)
  that holds the Telegram login and serves the API. The app never loads TDLib itself. On
  screen it is always called **the gateway**.
- **launchd**: the macOS service manager. A **LaunchAgent** is a launchd service that runs
  as the logged-in user; launchd starts it at login and restarts it if it exits.
- **`SMAppService`**: Apple's API (framework `ServiceManagement`) through which an app
  registers a LaunchAgent that ships inside its own bundle. Registered agents appear in
  System Settings → General → Login Items & Extensions, and macOS may ask the owner to
  allow them once.
- **Admin token**: the one token that may call `/v1/admin/*` (api.md "Authentication"). The
  daemon generates it on first run and writes it to the **secrets file**
  `~/Library/Application Support/TelegramGateway/secrets.json` (mode 0600, JSON
  `{"admin-token": "<base64 of the token>"}`); the app reads it from there. The login
  Keychain (service `TelegramGateway`, account `admin-token`) is an opt-in alternative for a
  shipped, stably-signed build, selected with `"secrets": "keychain"` in `config.json`.
  Development builds must not use it: every ad-hoc-signed rebuild is a new identity to the
  Keychain, so each read would prompt the owner for their password. Tests, previews and
  snapshots never touch it.
- **`api_id` / `api_hash`**: the identity of this software with Telegram, registered once at
  https://my.telegram.org ([development.md](development.md) "Register api_id / api_hash"). On
  screen: **API ID**, **API hash**, together "the Telegram key".
- **Panel**: the 360×520 window that opens under the menu bar icon.

## Words the owner sees

The panel is written for the owner, not for a developer. Identifiers from the API never
appear as text; they are tooltips at most. One mapping, in
`App/TelegramGateway/Services/Wording.swift`, unit-tested in `WordingTests`:

| In the API and the code | On screen |
|---|---|
| daemon, LaunchAgent, launchd | the gateway; "starts at login" |
| scope `messages:read` | New messages |
| scope `history:read` | Past messages |
| scope `media:read` | Photos and files |
| scope `chats:read` | Chat names and details |
| scope `messages:send` | Send messages |
| grant | an app that "has access" |
| access request | "*App* wants access" |
| webhook `paused` / `retrying` | "Delivery paused" / "Delivery failing" |
| webhook URL | its host only (`analytics.example.com`) |
| admin token | the gateway's "access key" |
| port 41414 | `127.0.0.1:41414` (never grouped as 41,414), in Gateway details only |
| chat type | Channel, Group, Person |

Telegram's own error codes are translated too (`API_ID_INVALID` → "Telegram doesn't
recognise the API ID and hash…", `wrong_password` → "That password isn't right.").

## The visual system

Every screen is built from the pieces in `App/TelegramGateway/Views/Design.swift` and nothing
else, so hierarchy reads the same everywhere.

- **Type scale**: screen title 15 semibold; row title 13 medium; body 13; secondary 11 in the
  secondary colour; section label 11 semibold, sentence case, never caps, never underlined.
  One size sits above it: the Overview's state line, 20 semibold.
- **Grouping**: related rows sit in one inset rounded card (quiet fill, 8pt radius, 12pt
  padding). Dividers appear only between rows inside a card and are inset to the text. 16pt
  between cards. No rule under a section label.
- **Action**: at most one prominent (accent-filled) button per screen; everything else is a
  plain or bordered button or a link. When a screen scrolls, its actions are in a fixed
  footer bar.
- **Colour means state only**: green = fine (a small dot), amber = waiting or needs the
  owner, red = failed. A card is tinted amber or red only for an exception; routine
  information is never coloured.
- **Help text** appears only where it states a consequence, a constraint, a risk or a way
  out.
- The prominent button and the checkboxes are drawn by the app (`PrimaryButtonStyle`,
  `CheckboxStyle`) rather than by AppKit, because AppKit greys both whenever the window is
  not the key window — which would also make every rendered snapshot show no primary action.

## Build and run

Requirements: Xcode 26 (Swift 6.3) and, for anything past step 1, a built daemon
(`swift build` in the repository root produces `.build/debug/GatewayDaemon`). XcodeGen is
not required: `App/TelegramGateway.xcodeproj` is checked in and builds from a clean checkout.
`App/project.yml` mirrors it for regenerating with `xcodegen generate` after structural
changes; keep both in sync.

```
# Build (Debug, ad-hoc signed):
xcodebuild -project App/TelegramGateway.xcodeproj -scheme TelegramGateway -configuration Debug build

# Build into App/.derived and launch (replaces a running copy):
App/run.sh

# Unit tests (46 tests: API decoding against api.md examples, login-link and QR handling,
# owner wording, every flow over the fake gateway), ~1s:
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
    Services/                  GatewayConfig (config.json), AdminToken (secrets.json; Keychain
                               opt-in), DaemonManager (SMAppService + child process),
                               QRCodeImage / LoginLink, Wording (owner vocabulary)
    State/AppModel.swift       @Observable state: screen from facts, header phrase, Overview
                               hero, "needs you", start flow, chat draft, approval draft, polling
    Views/                     Design (type scale, cards, styles), RootView (header, tabs),
                               ConnectView, LoginView, OverviewView, ChatsView, AppsView
                               (requests, app detail, approve), GatewayDetailsView
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

Starting the gateway writes the resolved path to `config.json` as `daemon_path` so the
launcher script (which launchd runs without the app's environment) finds the same binary.
Gateway details shows the path in use under Files → Program.

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

### How the gateway gets started

The owner is never asked how to run the gateway. **Continue** on step 1, **Start gateway**
when it is down, and **Try again** all call `AppModel.startGateway()`:

1. If the gateway already answers, restart it so it rereads the key
   (`launchctl kickstart -k gui/<uid>/com.brennancheung.telegram-gateway.daemon`, or stop and
   start the child process).
2. Otherwise register the LaunchAgent (`SMAppService.agent(plistName:).register()`) and wait
   up to 8s for `GET /v1/health` to answer.
3. If it does not — macOS wants approval first, registration failed, or the gateway stayed
   silent — run it as a **child process of the app** instead (after unregistering a
   registered-but-silent agent, so only one gateway ever runs) and wait up to 8s again.
4. If that fails too, the screen shows a red card **The gateway didn't start** with the
   reason in one line (the last line of the gateway's log when it exited, otherwise "It
   didn't answer on port 41414.") and **Show log**; the prominent button becomes **Try again**.

A gateway run as a child process stops when the app quits, so it does not satisfy goal #1 in
[goal.md](goal.md) ("closing the menu bar app does not stop it"). It exists so setup is never
blocked on the Login Items approval; Gateway details shows which way it is running
("Starts at login: Yes / No / Waiting for your approval / No, runs inside this app") and has
the switch to change it.

| Owner's action | App | launchd |
|---|---|---|
| **Continue** / **Start gateway** / **Try again** | `startGateway()` as above | loads the agent; runs the launcher now and at login |
| Gateway details → Start at login → **Turn On** | writes `daemon_path`, `register()` | same |
| Gateway details → Start at login → **Turn Off** | `unregister()` | stops the gateway, forgets the agent |
| Gateway details → Run inside this app → **Run** / **Stop** | spawns / terminates the child | untouched |
| **Restart gateway** (menu, or Gateway details) | `launchctl kickstart -k …`, or restarts the child | restarts the daemon |
| **Quit app** | quits (stops a child-process gateway) | untouched: a registered gateway keeps running |

### The Login Items approval step

The first time an app registers a LaunchAgent, macOS may require the owner to allow it.
What the owner sees:

1. After **Continue**, a system notification: *"Telegram Gateway" added items that can run
   in the background*. Setup does not wait for it: the gateway runs inside the app meanwhile.
2. ⋯ → **Gateway details** shows "Starts at login: Waiting for your approval" and a row
   **Allow at login → Open Settings**, which opens System Settings → General → Login Items &
   Extensions.
3. Under **Allow in the Background**, the switch next to **Telegram Gateway** must be on.
   (Ad-hoc-signed development builds may show the app's name as the developer.)
4. Back in Gateway details, **Start at login → Turn On** registers it again; "Starts at
   login" reads "Yes". If a child-process gateway is still running, stop it first (**Run
   inside this app → Stop**): two gateways cannot share one data directory, and the second
   one refuses to start.

Approval persists until the app's bundle path or signature changes.

## Screens

The panel decides its screen from facts, in this order (`AppModel.screen`):

| Facts | Screen |
|---|---|
| `config.json` lacks a valid `api_id`/`api_hash`, or the owner chose Change… in Gateway details | **Connect** (step 1) |
| `/v1/health` does not answer, first-run setup not finished | **Connect** (step 1, fields filled in) |
| `/v1/health` does not answer, set up before | **Gateway not running** |
| Gateway answers, no admin token can be read | **Can't control the gateway** |
| Gateway answers, `tdlib.auth_state` is not `ready` | **Sign in** (step 2) |
| Signed in | **Overview · Chats · Apps** |

"First-run setup finished" is remembered in the app's defaults (`onboardingDone`): it becomes
true when the owner first saves a monitored set, dismisses the step 3 banner, or the gateway
already monitors chats or serves apps. Until then the screens carry a quiet "Step N of 3".

**Header.** A status dot and one phrase: "Not set up yet", "Starting the gateway…", "Gateway
not running", "Scan the code to sign in", "Sign in to Telegram", "Finish signing in",
"Connected as @brennan", "Reconnecting to Telegram…", "Gateway needs attention". The ⋯ menu:
Refresh, Restart gateway, Gateway details…, Sign out of Telegram… (with confirmation), Quit
app (with the note that the gateway keeps running). There is no pause/resume entry because
the API has no such call; clearing the monitored set is the equivalent.

**Step 1 — Connect to Telegram.** One sentence, a link "Get your key at my.telegram.org ↗"
with the hint "API development tools → create an app (any name, platform Desktop)", the
fields **API ID** and **API hash**, and one prominent **Continue** in the footer. Continue
merges the key into `config.json` (keeping `port` and every other key) and starts the
gateway as described above. A field shows a red line only when its content cannot be valid
("The API hash is 32 characters, digits and a–f only (12 so far)."). No paths, no launchd
state, no manual controls.

**Step 2 — Scan to sign in.** The QR code, centred, with three numbered lines (Open Telegram
on your phone / Settings → Devices → Link Desktop Device / Point it at this code) and the
link **Use phone number instead**. The app polls `GET /v1/admin/auth` every 2s, asks for a
code once (`POST /v1/admin/auth/qr`) and redraws the image only when the token in the link
changes; renewal is silent. Only a failure replaces the code with "Couldn't get a code", the
reason, and **Refresh**. Phone, code, password and e-mail steps are one vertically centred
form each: title, one sentence, the field, a hint under it ("Sent to the Telegram app on
+1 ••• 42", "Hint: pet") or the error in red, the prominent button, and a Back / Start over
link; Return submits. A QR scan on an account with two-step verification lands on the same
password form. `wait_registration` explains that the gateway only signs in to existing
accounts.

**Step 3 — Choose chats.** First sign-in lands on the Chats tab with a one-time card: "Pick
the chats to monitor. Nothing else leaves the gateway."

**Overview.**
- *Hero card*: one state line — "Monitoring 3 chats" — and one secondary line "37 messages
  in the last hour · 4,812 total". When something is wrong the card is tinted and says what,
  with the one action: "Not monitoring any chats" → **Choose chats**; "Reconnecting to
  Telegram…" (no action; it recovers by itself).
- *Needs you*: present only when non-empty, amber. One row per pending request ("Community
  Analytics wants access" → **Review**) and per stopped or failing delivery ("Archive:
  delivery paused" → **Resume**).
- *Apps*: one row per app with access — name and a trailing state: a green dot with "1m ago"
  (last delivery or last connection), or amber "Paused" / "Failing". A row opens the Apps tab.
- A quiet footer line: "Gateway 0.1.0 · up 6h". Everything else about the gateway is in
  Gateway details.

**Gateway not running.** For an owner who is already set up: a red card "Gateway not
running — Nothing is monitored until it starts." and **Start gateway**; while starting, an
amber "Starting the gateway…"; on failure the same red "The gateway didn't start" card as in
step 1 with **Try again**.

**Chats.** Search on top. Sections in this order: **Monitored** (the monitored folders and
every chat currently monitored), **Folders**, **All chats**; each a card of rows. A row is a
checkbox, the type icon in a rounded square, the title, and one secondary line in a fixed
order with missing parts left out: "Channel · 13K members · @acmeupdates". A chat covered by
a ticked folder is ticked, locked, and says "via Product folder". The Folders section ends
with "A folder follows what you put in it on your phone." Ticks are a draft: section
membership follows what is saved (rows do not jump while ticking), the footer reads "3
monitored" until something changes, then "2 changes" with **Revert** and the prominent
**Save** (`PUT /v1/admin/monitored-chats` replaces the whole set).

**Apps.**
- Pending requests first, each an amber card: the name with the time left ("13 min left"),
  the app's description, then three labelled facts — **Wants** (the permissions as one
  sentence), **In** (the chats, one per line, with an amber "not monitored yet" on the ones
  that are not), **Sends to** (the webhook's host) — and **Deny** / **Review…** (prominent on
  the oldest request).
- **Has access**: one compact row per app — name, "2 chats · new messages, chat names"
  (a count once there are more than two permissions), the trailing state, a chevron. No
  Revoke on list rows.
- A row opens the **app's detail**: description, **Can read** (each permission with what it
  means), the chats (or "Chats in the Product folder"; a chat that is no longer monitored
  says so in amber), and delivery. A paused delivery is an amber card at the top with the
  reason, how many messages wait, and the prominent **Resume**. The footer has "Access since
  Sep 19" and **Revoke access…** (red, behind a confirmation that says it cannot be undone).
- Refreshes every 5s while the tab is open; the pending count is also polled in the
  background (every 15s while the panel is closed) for the menu bar badge.

**Approve ("Give *App* access").** A **Chats** card with a checkbox row per chat the app
asked for, pre-ticked; one that is not monitored says in amber "Not monitored yet —
approving starts monitoring it" (the app then runs `PUT /v1/admin/monitored-chats` before
`POST …/approve`, so the owner makes one decision — grants.md). "Show N other monitored
chats" adds the rest of the monitored set; "Follow a folder instead" switches the card to a
choice among monitored folders (and back). A request for "any" chats lists every monitored
chat. A **Can read** card has a checkbox per requested permission with its meaning. Fixed
footer: "3 chats · 3 permissions", **Cancel**, and the prominent **Approve**.

**Can't control the gateway.** The gateway answers but the app cannot read its access key
(the admin token): a red card saying so, **Restart gateway** (which makes the gateway write a
new one) and **Check again**.

**Gateway details** (⋯ menu). The only place with plumbing: Status, Address
(`127.0.0.1:41414`), Version, Running since, Starts at login; Controls (Restart, Allow at
login when macOS is waiting, Start at login Turn On/Off, Run inside this app Run/Stop, Log
Show); Telegram key (API ID, masked API hash, **Change…** which reopens step 1); Files
(Program, Settings, Log paths). It is an in-panel screen with Back rather than a sheet: a
menu bar panel closes when it loses focus, and sheets on it are unreliable.

## Checking the UI without clicking

Debug builds accept `--snapshot <directory>`: the app renders every screen and state with
the fake gateway into PNG files, light and dark (`NN-name.png`, `NN-name-dark.png`), and
quits. It never reads the Keychain, never registers anything with launchd, never writes
`config.json` and never persists to the app's defaults. `--only <prefix>` renders a subset.
The states, in order: connect, connect-didnt-start, signin-qr, signin-qr-failed,
signin-phone, signin-code, signin-password, signin-password-wrong, chats-first-run, overview,
overview-quiet, overview-reconnecting, overview-no-chats, gateway-down,
gateway-down-didnt-start, key-missing, chats, chats-unsaved, apps, apps-empty, approve,
approve-folder, app-detail, app-detail-paused, gateway-details.

`--live` instead drives the real HTTP client against whatever answers on the configured port
through a scripted flow (QR → phone → wrong code → code → wrong password → password →
overview → chats → save → apps → approve → app detail → revoke → sign out), printing each
step and saving a PNG after each:

```
App/.derived/Build/Products/Debug/TelegramGateway.app/Contents/MacOS/TelegramGateway --snapshot /tmp/shots
TGW_HOME=/tmp/tgw-scratch TGW_PORT=41498 …/TelegramGateway --snapshot /tmp/shots --live
```

`TGW_HOME` and `TGW_PORT` are honoured like the daemon honours them, so a scratch data
directory with its own `config.json` (and a second gateway started with `--home` and
`--port`) keeps a test away from the real one. Build into a separate
`-derivedDataPath` when the app from `App/.derived` is running, so its files are not replaced
under it.

When reviewing snapshots, check each screen for: the primary question answerable in two
seconds; one kind of information per visual region; routine states quiet and exceptions
visible; at most one prominent button; no copy that merely narrates; no dead space next to
crowding.

## Troubleshooting

**"Gateway not running" / "The gateway didn't start".** The app polls
`GET http://127.0.0.1:<port>/v1/health` and got no connection.
- The red card's one line is the reason; **Show log** opens
  `~/Library/Logs/TelegramGateway/daemon.log` (or `daemon-foreground.log` when the gateway
  was run inside the app).
- "The gateway program is missing": `.build/debug/GatewayDaemon` does not exist (run
  `swift build`) or `daemon_path` in `config.json` points somewhere stale. Gateway details →
  Files → Program shows the path in use.
- "It didn't answer on port 41414": `port` in
  `~/Library/Application Support/TelegramGateway/config.json` (default 41414) must be what
  the gateway listens on; `TGW_PORT` in the app's environment overrides it for the app only.
  Another program on the port shows up in the log as "Address already in use".
- `launchctl print gui/$(id -u)/com.brennancheung.telegram-gateway.daemon` shows launchd's
  view: `state = not running` with a non-zero `last exit code` means the gateway crashes on
  start.
- Gateway details says "Starts at login: Needs setting up again": the app bundle moved (for
  example `App/.derived` was deleted and rebuilt elsewhere). Start at login → Turn On.

**"Can't control the gateway".** The gateway is up but
`~/Library/Application Support/TelegramGateway/secrets.json` has no `admin-token` entry (or
does not exist).
- The gateway writes it on its first start; if it just started, **Check again**.
- The app and the gateway must use the same data directory: a gateway started with a custom
  `TGW_HOME` writes its `secrets.json` there, and the app reads `TGW_HOME` from its own
  environment (unset for an app launched from Finder or `open`).
- The secondary line names the problem when the file exists but is unreadable (not a JSON
  object, token not a string); fix or delete the file and **Restart gateway** to regenerate.
- "The gateway no longer accepts the app's access key" means the gateway regenerated it (for
  example `tgw` asked for a new one) after the app read it; Refresh re-reads the file.

**Keychain password prompts.** Only possible with `"secrets": "keychain"` in `config.json`,
which no development setup should have: the ad-hoc-signed app is a new "application" to the
Keychain after every rebuild, so each read prompts. Remove the key (or set `"file"`) and
restart the gateway so it writes `secrets.json`.

**The QR code does not scan, or the phone says it expired.** The link rotates roughly every
30s and the app redraws it within 2s of the gateway reporting a new one; keep the panel open
while scanning (closing it stops the 2s poll). "Couldn't get a code" with **Refresh** appears
only when the gateway could not obtain one — the reason is under it ("Telegram doesn't
recognise the API ID and hash" means the key from step 1 is wrong: ⋯ → Gateway details →
Telegram key → Change…). If nothing happens after a successful scan, the account probably has
two-step verification: the screen switches to the password form by itself.

**Login Items denied, or "Starts at login: Waiting for your approval".** System Settings →
General → Login Items & Extensions → *Allow in the Background* → switch **Telegram Gateway**
on, then Gateway details → Start at login → Turn On. A rebuild with a different bundle path
needs approval again. `sfltool resetbtm` (Apple's reset for the background task manager)
clears a wedged list; it requires a logout.

**Two gateways.** Never run `tgw`, or Run inside this app, while a registered gateway is
running on the same data directory: TDLib locks `td.binlog` and the second process refuses to
start (design.md "Why one TDLib owner"). Turn Start at login off first.

**Quitting the app does not stop the gateway.** That is by design (goal.md #1) when it starts
at login. To stop it: Gateway details → Start at login → Turn Off, or `launchctl bootout
gui/$(id -u)/com.brennancheung.telegram-gateway.daemon`. A gateway that runs inside the app
does stop with it.

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
  (number with no account).
- `/v1/admin/status.events_today` exists; the Overview uses `events_last_hour` and `head_seq`.
- `daemon_path` in `config.json` is tolerated by the daemon and listed in api.md.
- `secrets.json` holds `admin-token` base64-encoded (the app also accepts a raw `tgw_…`).
- There is no pause/resume-monitoring call, so the menu has no such entry.
- `requested_chats` in `GET /v1/admin/access-requests` is a list or the string `"any"`; the
  app decodes both.
- A webhook's failure count is not in the API, so a paused delivery is described by its last
  error ("connection refused") rather than "after N failures".
