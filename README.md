# Telegram Gateway

A macOS service that logs in to Telegram **as the owner's own user account** (not a bot) and
acts as a single, reusable gateway to that account for other applications.

It runs as a launchd LaunchAgent, owns the only TDLib instance on the machine, watches the
chats the owner picks, and delivers each new message as an event to applications the owner
has granted access to — over WebSocket or webhooks. A menu bar app handles login, choosing
which chats are monitored, and approving or revoking each application's access.

Nothing else on the machine should touch TDLib or its files. Every consumer goes through
the gateway's API.

## Where to start

| You want to… | Read |
|---|---|
| Understand why this exists and what "done" means | [docs/goal.md](docs/goal.md) |
| Understand how it is built and why | [docs/design.md](docs/design.md) |
| Integrate an application with the gateway | [docs/integrating.md](docs/integrating.md) |
| See the HTTP/WebSocket API | [docs/api.md](docs/api.md) |
| See the event format apps receive | [docs/events.md](docs/events.md) |
| Understand access grants and scopes | [docs/grants.md](docs/grants.md) |
| Build and run it locally | [docs/development.md](docs/development.md) |
| See what is built and what is next | [docs/status.md](docs/status.md) |

## Layout

```
Package.swift          Swift package: the daemon, the CLI and the shared library
Sources/
  CTDLib/              C module wrapping td_json_client.h (the raw TDLib JSON interface)
  TDLibClient/         Swift wrapper: one actor per TDLib client, typed auth flow, request/response correlation
  QRCode/              QR encoder for the terminal login
  GatewayCore/         Domain: store, monitored chats, event log, grants, translator, monitor, webhooks, media
  GatewayServer/       The HTTP + WebSocket API (Hummingbird) as a library, so tests drive it in-process
  GatewayDaemon/       The launchd service executable: wires TDLib, the store, the server, webhook delivery
  GatewayTestSupport/  Fakes and TDLib fixtures shared by the test targets
  tgw/                 Command-line tool: administers the daemon; direct TDLib commands for development
Tests/                 swift-testing suites (no account, no network)
launchd/               LaunchAgent plist template (tgw daemon install)
App/                   The SwiftUI menu bar app (Xcode project) — not started yet
vendor/tdlib/          Build script and pinned commit for libtdjson (built artifact is git-ignored)
docs/                  All documentation — the contract for integrators and agents
```

## Principles

- **Capability before UI.** Every feature exists as a library function first, then a CLI
  command, then a daemon endpoint, then something in the menu bar app.
- **One TDLib owner.** Only the daemon loads TDLib. TDLib's binlog cannot be shared and its
  SQLite database is encrypted and undocumented — see docs/design.md.
- **Our event format, not TDLib's.** Consumers never see raw TDLib JSON, so a TDLib upgrade
  never breaks them.
- **Nothing is lost.** Every event has a sequence number and is stored before delivery.
  Consumers resume from where they left off; the gateway backfills history after the Mac
  sleeps or goes offline.
- **Read-only by default.** Sending messages is not in the first version.
