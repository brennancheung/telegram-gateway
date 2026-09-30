# Menu bar app

The menu bar app (`App/`) is the owner's control panel for the gateway. It is a SwiftUI
application that talks to the gateway daemon over the local HTTP API in [api.md](api.md) with
the admin token. It has two surfaces, and each does one kind of job:

- **The menu bar popover** — a glance and three actions. How is it going, does anything
  need me, open the window. It opens from the paper-plane icon in the menu bar, is about
  300pt wide and only as tall as its content. It has no tabs, no forms and no lists to
  manage. A dot on the icon means an access request is waiting.
- **The main window** — everything with detail. A normal resizable macOS window: first-run
  setup and sign-in as a focused flow, then a sidebar with **Overview**, **Chats**, **Apps**
  and **Gateway**.

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
- **Activation policy**: whether macOS treats a process as a regular app (Dock icon, Cmd-Tab,
  its own menu bar) or as an accessory that lives only in the menu bar. This app switches
  between the two (see "Window behaviour").

## Words the owner sees

Both surfaces are written for the owner, not for a developer. Identifiers from the API never
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
| port 41414 | `127.0.0.1:41414` (never grouped as 41,414), in the Gateway section only |
| chat type | Channel, Group, Person |

Telegram's own error codes are translated too (`API_ID_INVALID` → "Telegram doesn't
recognise the API ID and hash…", `wrong_password` → "That password isn't right.").

## The visual system

Both surfaces are built from the pieces in `App/TelegramGateway/Views/Design.swift`, so
hierarchy reads the same everywhere.

- **Type scale**: screen title 15 semibold; row title 13 medium; body 13; secondary 11 in the
  secondary colour; section label 11 semibold, sentence case, never caps, never underlined.
  One size sits above it: the state line ("Monitoring 3 chats"), 20 semibold.
- **Grouping**: related rows sit in one inset rounded card (quiet fill, 8pt radius, 12pt
  padding). Dividers appear only between rows inside a card and are inset to the text. 16pt
  between cards. No rule under a section label.
- **Action**: at most one prominent button per screen; everything else is a plain or bordered
  button or a link. Where a screen scrolls, its actions are in a bar fixed at the bottom.
- **Colour means state only**: green = fine (a small dot), amber = waiting or needs the
  owner, red = failed. A card is tinted amber or red only for an exception; routine
  information is never coloured.
- **Help text** appears only where it states a consequence, a constraint, a risk or a way
  out.
- **Controls**: the main window is a real key window and uses native controls
  (`.borderedProminent`, native checkboxes, `Table`, sidebar list, toolbar search). The
  popover's one prominent button is drawn by the app (`PrimaryButtonStyle`), because a menu
  bar popover is not always the key window and AppKit greys prominent buttons in an inactive
  one.

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

# Unit tests (49 tests: API decoding against api.md examples, login-link and QR handling,
# owner wording, every flow over the fake gateway), ~1s:
App/run.sh --test

# Render every state of both surfaces to PNG (see "Checking the UI without clicking"):
App/snapshot.sh /tmp/shots
```

Or open `App/TelegramGateway.xcodeproj` in Xcode and press Run. Every screen has a preview
(`#Preview`) backed by `FakeAPIClient`, so the UI can be worked on without a daemon.

### Where things are

```
App/
  TelegramGateway.xcodeproj    Xcode project (synchronized folders: no file lists to maintain)
  project.yml                  XcodeGen mirror of the project
  run.sh                       build + launch, or --test
  snapshot.sh                  renders every state of both surfaces to PNG
  Support/Info.plist           LSUIElement, TGWRepositoryRoot ($(SRCROOT)/.., development only)
  Support/gateway-launcher     the script launchd runs; finds and execs the daemon binary
  Support/LaunchAgents/com.brennancheung.telegram-gateway.daemon.plist   the LaunchAgent
  TelegramGateway/
    TelegramGatewayApp.swift   @main: MenuBarExtra (popover) and Window (main window) scenes,
                               commands, menu bar icon with badge
    API/                       APIClient protocol, HTTPAPIClient (URLSession), FakeAPIClient, models
    Services/                  GatewayConfig (config.json), AdminToken (secrets.json; Keychain
                               opt-in), DaemonManager (SMAppService + child process),
                               QRCodeImage / LoginLink, Wording (owner vocabulary)
    State/AppModel.swift       @Observable state: screen from facts, state line, "needs you",
                               window requests, start flow, chat draft, approval draft, polling
    Views/Design.swift         type scale, cards, rows, shared styles
    Views/Popover/             PopoverView
    Views/Window/              MainWindow (split view, WindowCoordinator), SetupFlow (connect,
                               sign in), OverviewSection, ChatsSection (Table), AppsSection
                               (list, detail, review sheet), GatewaySection
    Debug/SnapshotRunner.swift `--snapshot` mode (Debug builds only)
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
The Gateway section shows the path in use under Files → Program.

**A shipped build** (TODO, not done): a build phase copies the release `GatewayDaemon` and
`libtdjson.dylib` into `Contents/MacOS/`, `gateway-launcher`'s last fallback already points
there, the daemon's `@rpath` must resolve to the bundled dylib, and the bundle is signed with a
Developer ID (at which point `"secrets": "keychain"` becomes usable without prompts). Until
then the app is a development tool that runs the daemon from the repository.

## Window behaviour

The app is an `LSUIElement` application: launched, it has no Dock icon and no menu bar of
its own, only the paper-plane icon.

- **The window opens on request**: "Open Telegram Gateway…" in the popover, a "Needs you"
  row, or Cmd-, while the app is frontmost. There is exactly one main window (a SwiftUI
  `Window` scene, default 820×560, minimum 700×460); asking again re-focuses it rather than
  making another, and there is no New Window command.
- **The window opens by itself** on first run and whenever setup or sign-in becomes
  necessary, because neither can be done from the popover. It does so once per occurrence:
  if the owner closes it while still signed out it stays closed, and the popover keeps
  saying "Not signed in". Launching the app when everything is fine opens nothing.
- **While the window is open the app is a regular app** (`NSApp.setActivationPolicy(.regular)`):
  Dock icon, Cmd-Tab, and a normal menu bar with Edit and Window, so Cmd-V, Cmd-W and Return
  work in its fields. Opening always brings it to the front (`NSApp.activate`).
- **Closing the window never quits the app.** The app goes back to `.accessory` (menu bar
  only) and the gateway is unaffected. Quit is in the popover and in the app menu.

Mechanics: every way of opening goes through `AppModel.requestWindow()`, which bumps a
counter; the menu bar label view (always alive) observes it and calls
`openWindow(id: "main")` and `WindowCoordinator.focus()`. `WindowCoordinator` receives the
hosting `NSWindow` from a probe view, and switches the policy back on
`NSWindow.willCloseNotification`. The `Window` scene has `.defaultLaunchBehavior(.suppressed)`
and `.restorationBehavior(.disabled)`, so macOS never opens it just because the app launched.

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
on Overview when it is down, and **Try again** all call `AppModel.startGateway()`:

1. If the gateway already answers, restart it so it rereads the key
   (`launchctl kickstart -k gui/<uid>/com.brennancheung.telegram-gateway.daemon`, or stop and
   start the child process).
2. Otherwise register the LaunchAgent (`SMAppService.agent(plistName:).register()`) and wait
   up to 8s for `GET /v1/health` to answer.
3. If it does not — macOS wants approval first, registration failed, or the gateway stayed
   silent — run it as a **child process of the app** instead (after unregistering a
   registered-but-silent agent, so only one gateway ever runs) and wait up to 8s again.
4. If that fails too, the screen says **The gateway didn't start** in red with the reason in
   one line (the last line of the gateway's log when it exited, otherwise "It didn't answer
   on port 41414.") and **Show log**; the prominent button becomes **Try again**.

A gateway run as a child process stops when the app quits, so it does not satisfy goal #1 in
[goal.md](goal.md) ("closing the menu bar app does not stop it"). It exists so setup is never
blocked on the Login Items approval; the Gateway section shows which way it is running
("Starts at login: Yes / No / Waiting for your approval / No, runs inside this app") and has
the switch to change it. The popover's Quit row says "The gateway stops too" in that case.

| Owner's action | App | launchd |
|---|---|---|
| **Continue** / **Start gateway** / **Try again** | `startGateway()` as above | loads the agent; runs the launcher now and at login |
| Gateway → Start at login → **Turn on** | writes `daemon_path`, `register()` | same |
| Gateway → Start at login → **Turn off** | `unregister()` | stops the gateway, forgets the agent |
| Gateway → Run inside this app → **Run** / **Stop** | spawns / terminates the child | untouched |
| **Restart gateway** (popover, or Gateway → Restart) | `launchctl kickstart -k …`, or restarts the child | restarts the daemon |
| **Quit** | quits (stops a child-process gateway) | untouched: a registered gateway keeps running |

### The Login Items approval step

The first time an app registers a LaunchAgent, macOS may require the owner to allow it.
What the owner sees:

1. After **Continue**, a system notification: *"Telegram Gateway" added items that can run
   in the background*. Setup does not wait for it: the gateway runs inside the app meanwhile.
2. The **Gateway** section shows "Starts at login: Waiting for your approval" and a row
   **Allow at login → Open settings**, which opens System Settings → General → Login Items &
   Extensions.
3. Under **Allow in the Background**, the switch next to **Telegram Gateway** must be on.
   (Ad-hoc-signed development builds may show the app's name as the developer.)
4. Back in Gateway, **Start at login → Turn on** registers it again; "Starts at login" reads
   "Yes". If a child-process gateway is still running, stop it first (**Run inside this app
   → Stop**): two gateways cannot share one data directory, and the second one refuses to
   start.

Approval persists until the app's bundle path or signature changes.

## The popover

Top to bottom, and nothing else:

- **The state line**, in a card: "Monitoring 3 chats" with one secondary line "37 messages
  in the last hour · 4,812 total". When something is wrong the card is amber or red and says
  what: "Not set up yet", "Not signed in", "Reconnecting…", "Not monitoring any chats",
  "Gateway not running", "Can't control the gateway".
- **Needs you**, an amber card, only when non-empty: one row per pending access request
  ("Community Analytics wants access", "13 min left"), per stopped or failing delivery
  ("Archive: delivery paused", "Connection refused"), and for whatever keeps the gateway
  from working ("Set up Telegram Gateway", "Sign in to Telegram", "Start the gateway",
  "Restart the gateway", "Choose chats to monitor"). Clicking a row opens the main window at
  the place where it is dealt with: the request's review sheet, the app's detail, the
  sign-in flow, Overview, Chats.
- **Actions**: **Open Telegram Gateway…** (the prominent one), **Restart gateway**, and
  **Quit** with the line "The gateway keeps running".

## The main window

`AppModel.screen` decides what the window shows from facts, in this order:

| Facts | The window shows |
|---|---|
| `config.json` lacks a valid `api_id`/`api_hash`, or the owner chose Edit… in Gateway | **Connect** (step 1), no sidebar |
| `/v1/health` does not answer, first-run setup not finished | **Connect** (step 1, fields filled in), no sidebar |
| Gateway answers, `tdlib.auth_state` is not `ready` | **Sign in** (step 2), no sidebar |
| `/v1/health` does not answer, set up before | sidebar; Overview says "Gateway not running" |
| Gateway answers, no admin token can be read | sidebar; Overview says "Can't control the gateway" |
| Signed in | sidebar: Overview, Chats, Apps, Gateway |

"First-run setup finished" is remembered in the app's defaults (`onboardingDone`): it becomes
true when the owner first saves a monitored set, dismisses the step 3 banner, or the gateway
already monitors chats or serves apps. Until then the flow carries a quiet "Step N of 3".

The sidebar's foot shows one dot and one phrase ("Connected as @brennan", "Reconnecting to
Telegram…", "Gateway not running", "Gateway needs attention"). The Apps row carries a badge
with the number of pending requests.

### Setup and sign-in (no sidebar)

One centred column; the window title is "Telegram Gateway".

**Step 1 — Connect to Telegram.** One sentence, a link "Get your key at my.telegram.org ↗"
with the hint "API development tools → create an app (any name, platform Desktop)", the
fields **API ID** and **API hash**, and one prominent **Continue**. Continue merges the key
into `config.json` (keeping `port` and every other key) and starts the gateway as described
above. A field shows a red line only when its content cannot be valid. If starting fails: a
red card "The gateway didn't start", the reason in one line, **Show log**, and the button
becomes **Try again**. No paths, no launchd state, no manual controls.

**Step 2 — Scan to sign in.** The QR code on the left, and on the right the title and three
numbered lines (Open Telegram on your phone / Settings → Devices → Link Desktop Device /
Point it at this code) with the link **Use phone number instead**. The app polls
`GET /v1/admin/auth` every 2s, asks for a code once (`POST /v1/admin/auth/qr`) and redraws
the image only when the token in the link changes; renewal is silent. Only a failure replaces
the code with "Couldn't get a code", the reason, and **Refresh**. Phone, code, password and
e-mail steps are one centred form each: title, one sentence, the field, a hint under it
("Sent to the Telegram app on +1 ••• 42", "Hint: pet") or the error in red, the prominent
button, and a Back / Start over link; Return submits. A QR scan on an account with two-step
verification lands on the same password form. `wait_registration` explains that the gateway
only signs in to existing accounts. A quiet link at the bottom, **Change the Telegram
key…**, goes back to step 1 (the way out when Telegram rejects the key).

**Step 3 — Choose chats.** After the first sign-in the sidebar appears with Chats selected
and a one-time card above the table: "Pick the chats to monitor. Nothing else leaves the
gateway."

### Overview

- *Hero*, across the top: the state line and one secondary line; when something is wrong
  the card is tinted and carries the one action — "Not monitoring any chats" → **Choose
  chats**; "Gateway not running" → **Start gateway**; "The gateway didn't start" with the
  reason and **Show log** → **Try again**; "Can't control the gateway" → **Restart gateway**
  (and Check again); "Reconnecting…" has no action, it recovers by itself.
- *Needs you*: present only when non-empty, amber. One row per pending request (→
  **Review…**, which opens the review sheet) and per stopped or failing delivery (→
  **Resume**).
- *Apps*: one row per app with access — name and a trailing state: a green dot with "1m ago"
  (last delivery or last connection), or amber "Paused" / "Failing". A row opens that app in
  the Apps section.
- Needs you and Apps sit side by side when the window is wide (detail area ≥ 700pt), stacked
  otherwise.
- A quiet footer line: "Gateway 0.1.0 · up 6h".

### Chats

A `Table` with the columns **Monitored** (checkbox), **Chat** (type icon and title),
**Type** (Folder, Channel, Group, Person), **Members** and **Username**; every column sorts.
The toolbar has a scope control — **Monitored / Folders / All** — and the search field.
Unsorted, monitored rows come first (their place follows what is saved, so rows do not jump
while ticking). A chat covered by a ticked folder is ticked, locked, and says "via Product
folder" under its title. Ticks are a draft: the bottom bar reads "3 monitored" until
something changes, then "2 unsaved changes" with **Revert** and the prominent **Save**
(Cmd-S; `PUT /v1/admin/monitored-chats` replaces the whole set). The bar also carries the one
folder fact: "A folder follows what you put in it on your phone."

### Apps

A list on the left and the selected item's detail on the right.

- The list: **Wants access** first (each pending request with an amber dot and the time
  left), then **Has access** (name, trailing state, and one line such as "2 chats · new
  messages, chat names" — a count once there are more than two permissions). The oldest
  request is selected by default.
- A selected request: an amber card with the name, "Wants access · 13 min left", the app's
  description, and three labelled facts — **Wants** (the permissions as one sentence),
  **In** (the chats, one per line, with an amber "not monitored yet" on the ones that are
  not), **Sends to** (the webhook's host) — then **Deny** and the prominent **Review…**.
- A selected app: description, **Can read** (each permission with what it means), the chats
  (or "Chats in the Product folder"; a chat that is no longer monitored says so in amber),
  and delivery. A paused delivery is an amber card at the top with the reason, how many
  messages wait, and the prominent **Resume**. The bottom bar has "Access since Sep 19" and
  **Revoke access…** (red, behind a confirmation that says it cannot be undone).
- **The review sheet** ("Give *App* access"), a sheet on the window: a **Chats** card with a
  checkbox row per chat the app asked for, pre-ticked; one that is not monitored says in
  amber "Not monitored yet — approving starts monitoring it" (the app then runs
  `PUT /v1/admin/monitored-chats` before `POST …/approve`, so the owner makes one decision —
  grants.md). "Show N other monitored chats" adds the rest of the monitored set; "Follow a
  folder instead" switches the card to a choice among monitored folders (and back). A
  request for "any" chats lists every monitored chat. A **Can read** card has a checkbox per
  requested permission with its meaning. Bottom bar: "3 chats · 3 permissions", **Cancel**
  (Esc), and the prominent **Approve** (Return).
- Refreshes every 5s while the section is open; the pending count is also polled in the
  background (every 15s while neither surface is open) for the menu bar badge.

### Gateway

The only place with plumbing. **Gateway**: Status, Address (`127.0.0.1:41414`), Version,
Started, Uptime, Starts at login. **Controls**: Restart; Allow at login (when macOS is
waiting); Start at login Turn on / Turn off; Run inside this app Run / Stop; Log → Show log.
**Telegram**: the account with **Sign out…** (confirmed), API ID, masked API hash with
**Edit…** (reopens step 1). **Files**: Program, Settings, Log paths. Two columns when the
window is wide enough.

Chats and Apps show "Gateway not running — Overview has the way to fix it" while the gateway
cannot serve them; Overview and Gateway keep working.

## Checking the UI without clicking

`App/snapshot.sh <directory>` renders every state of both surfaces with the fake gateway
into PNG files, light and dark: `p01…p08` are the popover, `w01…w30` the main window (the
review sheet is `w27`, `w28`).

```
App/run.sh --no-launch               # or any Debug build
App/snapshot.sh /tmp/shots           # all states
App/snapshot.sh /tmp/shots --only w2 # a subset by file-name prefix
App/snapshot.sh /tmp/shots --key     # as key windows: takes keyboard focus while it runs
APP_BIN=/path/to/TelegramGateway App/snapshot.sh /tmp/shots   # another build
```

How it works: the app, started with `--snapshot <directory> --shoot`, steps through its
states. Popover and sheet states it renders itself. For each main-window state it shows a
real window, writes `<directory>/.shoot` ("<window number> <file name>") and waits; the
script photographs that window with `screencapture -l` and removes the file. The window is
photographed from outside because an in-process render cannot see the sidebar, which macOS
draws in a separate layer; this needs Screen Recording permission for the terminal.

Without `--key` the windows are not key, and AppKit draws native controls in an inactive
window grey (prominent buttons, checkboxes, selection, the window's traffic lights). That is
fine for layout work. For a final check use `--key`, which shows them as the owner sees them.
It launches the app through LaunchServices (`open -n -W`), because macOS lets a launched app
come to the front but ignores the same request from a binary started in a shell, and it takes
keyboard focus for the duration (about 01:40 for the full set). A capture taken while
something else had the focus (someone clicked another window mid-run) still comes out grey;
re-render that state with `--only <name>`. The script exits with an error if the app was quit
before the last state.

A snapshot run never reads the Keychain, never registers anything with launchd, never writes
`config.json` and never persists to the app's defaults. When the app from `App/.derived` is
running, build into a separate `-derivedDataPath` and pass `APP_BIN`, so its files are not
replaced under it.

`--snapshot <directory> --live` instead drives the real HTTP client against whatever answers
on the configured port through a scripted flow (QR → phone → wrong code → code → wrong
password → password → overview → chats → save → apps → review → approve → revoke → gateway →
sign out), printing each step:

```
TGW_HOME=/tmp/tgw-scratch TGW_PORT=41498 …/TelegramGateway --snapshot /tmp/shots --live
```

`TGW_HOME` and `TGW_PORT` are honoured like the daemon honours them, so a scratch data
directory with its own `config.json` (and a second gateway started with `--home` and
`--port`) keeps a test away from the real one.

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
  `swift build`) or `daemon_path` in `config.json` points somewhere stale. Gateway → Files →
  Program shows the path in use.
- "It didn't answer on port 41414": `port` in
  `~/Library/Application Support/TelegramGateway/config.json` (default 41414) must be what
  the gateway listens on; `TGW_PORT` in the app's environment overrides it for the app only.
  Another program on the port shows up in the log as "Address already in use".
- `launchctl print gui/$(id -u)/com.brennancheung.telegram-gateway.daemon` shows launchd's
  view: `state = not running` with a non-zero `last exit code` means the gateway crashes on
  start.
- Gateway says "Starts at login: Needs setting up again": the app bundle moved (for example
  `App/.derived` was deleted and rebuilt elsewhere). Start at login → Turn on.

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
  example `tgw` asked for a new one) after the app read it; the next refresh re-reads the file.

**Keychain password prompts.** Only possible with `"secrets": "keychain"` in `config.json`,
which no development setup should have: the ad-hoc-signed app is a new "application" to the
Keychain after every rebuild, so each read prompts. Remove the key (or set `"file"`) and
restart the gateway so it writes `secrets.json`.

**The QR code does not scan, or the phone says it expired.** The link rotates roughly every
30s and the app redraws it within 2s of the gateway reporting a new one; keep the window open
while scanning (closing it stops the 2s poll). "Couldn't get a code" with **Refresh** appears
only when the gateway could not obtain one — the reason is under it ("Telegram doesn't
recognise the API ID and hash" means the key from step 1 is wrong: **Change the Telegram
key…** at the bottom of the sign-in screen). If nothing happens after a successful scan, the
account probably has two-step verification: the screen switches to the password form by
itself.

**The window does not appear, or the Dock icon stays after closing it.** The window is
opened only through `AppModel.requestWindow()`; check that the menu bar icon is present (the
label view carries out the request). The Dock icon follows the window: it appears when the
window opens and goes when the window closes. If it lingers, another window of the app is
still open (a confirmation dialog or the review sheet counts until dismissed).

**Login Items denied, or "Starts at login: Waiting for your approval".** System Settings →
General → Login Items & Extensions → *Allow in the Background* → switch **Telegram Gateway**
on, then Gateway → Start at login → Turn on. A rebuild with a different bundle path needs
approval again. `sfltool resetbtm` (Apple's reset for the background task manager) clears a
wedged list; it requires a logout.

**Two gateways.** Never run `tgw`, or Run inside this app, while a registered gateway is
running on the same data directory: TDLib locks `td.binlog` and the second process refuses to
start (design.md "Why one TDLib owner"). Turn Start at login off first.

**Quitting the app does not stop the gateway.** That is by design (goal.md #1) when it starts
at login. To stop it: Gateway → Start at login → Turn off, or `launchctl bootout
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
- `/v1/admin/status.events_today` exists; the state line uses `events_last_hour` and `head_seq`.
- `daemon_path` in `config.json` is tolerated by the daemon and listed in api.md.
- `secrets.json` holds `admin-token` base64-encoded (the app also accepts a raw `tgw_…`).
- There is no pause/resume-monitoring call, so neither surface has such an action.
- `requested_chats` in `GET /v1/admin/access-requests` is a list or the string `"any"`; the
  app decodes both.
- A webhook's failure count is not in the API, so a paused delivery is described by its last
  error ("connection refused") rather than "after N failures".
