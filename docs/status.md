# Status

Updated: 2026-09-29

## Built

Nothing yet. Repository created; design and contract documents written.

## In progress

- Foundation: TDLib build script, `CTDLib`, `TDLibClient`, `tgw login`, `tgw watch`.
- Contract documents: `docs/api.md`, `docs/events.md`, `docs/grants.md`, `docs/integrating.md`.

## Next

- Daemon: store, monitored chats, event log, backfill, WebSocket, webhooks, access requests.
- Menu bar app.
- First consumer (separate repo).

## Open questions

- Does TDLib deliver `updateNewMessage` promptly for large channels the account has joined
  but never opened? The foundation step measures this with the real account.
