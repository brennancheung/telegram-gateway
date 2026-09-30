# Telegram Gateway

A macOS service that signs in to Telegram **as you** — your own user account, not a bot — and
gives other programs scoped, revocable access to the chats you choose.

You sign in once. You pick which channels and groups are monitored. Any app that wants your
Telegram messages asks the gateway for access; you approve it, limit it to specific chats, and
can revoke it with one click. Approved apps receive each new message as an event over
WebSocket or webhooks.

```
                       ┌───────────────────────────────────────────┐
  Telegram  ⇄  TDLib ⇄ │  gateway (background service on your Mac)  │ ⇄  your apps
                       │  monitored chats · event log · grants      │    WebSocket · webhooks · HTTP
                       └───────────────────────────────────────────┘
                              ▲ menu bar app        ▲ tgw (CLI)
```

## Why

Reading Telegram as a user normally means every project embeds its own Telegram client and
asks for your login. Bots avoid that, but a bot has to be added to every chat and cannot see
what you see.

The gateway puts the login in one place:

- **One sign-in, many apps.** Apps never see your Telegram credentials or session. They get a
  token that works only against the gateway.
- **You choose what is shared.** Only chats you mark as monitored ever leave the gateway, and
  each app is limited to the chats and permissions you grant it.
- **Nothing is lost.** Every event is numbered and stored before delivery. An app that was
  offline resumes from the last event it saw; after your Mac sleeps, the gateway fetches what
  it missed.
- **It stays out of your way.** The gateway is read-only: it never sends messages, never marks
  anything as read, and never shows you as online.

Typical uses: watching channels for mentions of your product, collecting support questions
from community groups, feeding industry news into a summarizer, counting what a community
talks about. The gateway only delivers messages; analysis belongs in the apps.

## Status

Early. The gateway, the command-line tool and the menu bar app build and pass their test
suites, and run together on macOS. The path from a real Telegram sign-in through to delivered
events has not yet been verified end to end. See [docs/status.md](docs/status.md) for what
works, what is unverified, and what is planned.

## Requirements

- macOS 15 or later on Apple silicon
- Xcode with Swift 6 (developed with Xcode 26)
- `cmake`, `gperf` and OpenSSL to build TDLib: `brew install cmake gperf openssl@3`
- A Telegram **API ID** and **API hash** of your own, free from
  [my.telegram.org](https://my.telegram.org) → *API development tools* (any app name,
  platform *Desktop*). Telegram requires every client program to have one; do not reuse
  another application's.

## Quick start

```sh
git clone https://github.com/brennancheung/telegram-gateway.git
cd telegram-gateway

./vendor/tdlib/build.sh          # builds TDLib from source (about 2 minutes)
swift build                      # the gateway and the tgw command-line tool
.build/debug/tgw daemon install  # starts the gateway now and at every login
App/run.sh                       # builds and opens the menu bar app
```

The app opens a window and walks you through three steps:

1. **Connect** — paste your API ID and API hash.
2. **Sign in** — scan the QR code from your phone (Telegram → Settings → Devices → Link
   Desktop Device), or use your phone number. The gateway appears in your device list like
   any other Telegram client, and you can end its session from there at any time.
3. **Choose chats** — tick the channels, groups or folders to monitor.

After that the app lives in the menu bar. It shows the gateway's state and anything that
needs you, such as an app asking for access. [docs/app.md](docs/app.md) covers every screen.

## Connecting an app

An app asks for access, you approve it in the menu bar app, and the app receives a token.

```sh
# 1. Ask for access
curl -s http://127.0.0.1:41414/v1/access-requests \
  -H 'Content-Type: application/json' \
  -d '{"name": "Community Analytics",
       "description": "Counts topics per day in product channels.",
       "scopes": ["messages:read", "chats:read"],
       "requested_chats": "any"}'
# → {"request_id": "req_…", "poll_url": "/v1/access-requests/req_…", "status": "pending", …}

# 2. Poll until it is approved; the token is handed over once
curl -s http://127.0.0.1:41414/v1/access-requests/req_…
# → {"status": "approved", "token": "tgw_…", "grant": {…}}

# 3. Read events, resuming from the last sequence number you processed
curl -s 'http://127.0.0.1:41414/v1/events?since=0' -H 'Authorization: Bearer tgw_…'
```

Each event is a small JSON object in the gateway's own format, independent of Telegram's:

```json
{
  "v": 1,
  "seq": 4810,
  "type": "message.new",
  "occurred_at": "2026-09-29T14:03:07Z",
  "chat": { "id": "-1001234567890", "type": "channel", "title": "Acme Product Updates" },
  "message": { "id": "812", "text": "v2.4 is out.", "sender": { … }, "media": [] }
}
```

For a live stream, connect a WebSocket to `/v1/events/stream?since=<seq>`, or register a
webhook and let the gateway deliver signed batches to your server.
[docs/integrating.md](docs/integrating.md) is the step-by-step guide, with a complete
consumer.

## Documentation

| If you want to… | Read |
|---|---|
| Use the menu bar app | [docs/app.md](docs/app.md) |
| Build an app that receives messages | [docs/integrating.md](docs/integrating.md) |
| Look up an endpoint | [docs/api.md](docs/api.md) |
| Look up the event format | [docs/events.md](docs/events.md) |
| Understand what an app can and cannot see | [docs/grants.md](docs/grants.md) |
| Understand how the gateway works | [docs/architecture.md](docs/architecture.md) |
| Build, run and contribute | [docs/development.md](docs/development.md) |
| See what works and what is planned | [docs/status.md](docs/status.md) |

## What it does not do

- **Send messages.** The gateway is read-only. A permission for sending is reserved but not
  implemented.
- **Analyze anything.** No classification, sentiment or search. Apps do that.
- **Serve other machines directly.** The API listens on `127.0.0.1` only. An app running
  elsewhere can still receive events through webhooks.
- **Handle more than one Telegram account**, or run on anything but macOS.

## Security and privacy

- The API is reachable only from your own Mac. Every request needs a token, and tokens are
  stored only as hashes.
- Your Telegram session is kept in TDLib's encrypted database under
  `~/Library/Application Support/TelegramGateway/`. Apps never get access to it.
- Chats you have not marked as monitored — including your private conversations — are never
  stored in the event log or delivered to any app.
- The gateway uses [TDLib](https://core.telegram.org/tdlib), Telegram's official client
  library, built from source at a pinned commit.

You are running a client on your own account, so Telegram's
[terms of service](https://core.telegram.org/api/terms) apply to what you do with it.

## Repository layout

```
Sources/
  CTDLib/           C module over TDLib's JSON interface
  TDLibClient/      Swift wrapper: requests, updates, sign-in states
  GatewayCore/      store, event log, grants, translation from TDLib to events, delivery
  GatewayServer/    the HTTP and WebSocket API
  GatewayDaemon/    the background service
  tgw/              command-line tool
App/                the menu bar app (Xcode project)
vendor/tdlib/       build script and pinned commit for TDLib
launchd/            LaunchAgent template
docs/               documentation
```

## Contributing

Issues and pull requests are welcome. [docs/development.md](docs/development.md) explains how
to build and test; [AGENTS.md](AGENTS.md) lists the rules that keep the gateway safe to run on
a real account, for human contributors and coding agents alike.

## License

[MIT](LICENSE)
