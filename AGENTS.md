# Agents working in this repository

Read `README.md` first, then `docs/goal.md` and `docs/design.md`. They are the contract.
`docs/status.md` says what is built and what is next — update it when you finish something.

Rules:

- **Capability before UI.** Library function → `tgw` command → daemon endpoint → menu bar app.
  Never build UI for something that does not work from the CLI yet.
- **Only the daemon loads TDLib.** Never open TDLib's directory from anything else, never run
  two TDLib instances on the same directory. See docs/design.md "Why one TDLib owner".
- **Consumers never see TDLib JSON.** Anything crossing the API is in the format in
  `docs/events.md` / `docs/api.md`. If you change the format, change the doc in the same commit.
- **Do not send messages, mark as read, or set online status** from any code path. The account
  is the owner's real account.
- **Never commit** the TDLib build artifact, `api_id`/`api_hash`, tokens, or anything from
  `~/Library/Application Support/TelegramGateway/`.
- **Use the pinned TDLib commit** in `vendor/tdlib/COMMIT`. Bumping it is a deliberate change.
- Swift 6 strict concurrency. Actors for anything holding TDLib or SQLite state.
- `swift build` and `swift test` must pass before handing back.
- Documentation lives in `docs/`, never elsewhere. Write for a reader who has never seen
  Telegram's API: define every term the first time you use it.
- Commit messages: subject + body, no attribution trailers.
