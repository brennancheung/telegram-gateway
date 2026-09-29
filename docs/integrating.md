# Integrating an application

A step-by-step guide to building an application that consumes Telegram messages through the
gateway. It assumes you have read nothing else; the precise contract is in
[api.md](api.md) (endpoints), [events.md](events.md) (event format) and
[grants.md](grants.md) (access model), and this guide links into them.

Durations are written `mm:ss` (or `h:mm:ss`); values under a minute as seconds.

## Contents

1. [What you are talking to](#1-what-you-are-talking-to)
2. [Request access](#2-request-access)
3. [Poll for approval](#3-poll-for-approval)
4. [Choose WebSocket or webhooks](#4-choose-websocket-or-webhooks)
5. [Connect and resume with `since`](#5-connect-and-resume-with-since)
6. [Handle heartbeat and reconnect](#6-handle-heartbeat-and-reconnect)
7. [Verify webhook signatures](#7-verify-webhook-signatures)
8. [Dedupe on `seq`](#8-dedupe-on-seq)
9. [Read history for backfilling](#9-read-history-for-backfilling)
10. [Fetch media](#10-fetch-media)
11. [A minimal complete WebSocket consumer](#11-a-minimal-complete-websocket-consumer)
12. [Your integration is correct when…](#12-your-integration-is-correct-when)

---

## 1. What you are talking to

The **gateway** is a background process on the owner's Mac that is logged in to Telegram as
the owner's own user (not a bot). It watches the chats the owner has chosen ("monitored
chats"), turns every message in them into an **event** in the gateway's own JSON format,
numbers each event with a **sequence number** (`seq`), and stores it before delivering it.
Your application never talks to Telegram: it talks to the gateway at

```
http://127.0.0.1:41414
```

with a **token** the owner granted it, and reads events either by holding a **WebSocket**
(a persistent two-way connection over HTTP) or by exposing a **webhook** (an HTTPS URL the
gateway posts to). Because every event has a `seq` and the gateway keeps them, your app can
restart, crash, or be offline for a week and resume exactly where it stopped by passing back
the last `seq` it processed. This is called a **cursor**, and your application owns it.

Terms you will meet: a **chat** is any Telegram conversation (a channel, a group, a private
chat); a **chat id** is its Telegram number, always given as a string; a **scope** is a kind
of access (`messages:read`, …); a **grant** is your app's approved access (scopes + chats +
token). All defined in [api.md](api.md#conventions) and [grants.md](grants.md).

Check the gateway is up before anything else:

```
GET http://127.0.0.1:41414/v1/health
```

`status: "ok"` means logged in and connected. `"degraded"` with `tdlib.auth_state` other than
`ready` means the owner has not logged in yet; events endpoints still work for stored events
but nothing new arrives.

---

## 2. Request access

Decide the scopes you need (table in [grants.md](grants.md#scopes)) — ask for the least. Then:

```http
POST /v1/access-requests
Content-Type: application/json

{
  "name": "Community Analytics",
  "description": "Classifies messages in product channels and counts topics per day.",
  "scopes": ["messages:read", "history:read", "chats:read"],
  "requested_chats": "any"
}
```

Add `"webhook": { "url": "https://…" }` if you chose webhooks (step 4). The response gives
you `request_id` and `poll_url`. The owner now sees a card in their menu bar app with your
name and description — write the description for them, one sentence saying what you do with
the messages.

`requested_chats` is a suggestion. If you know the chat ids you want, list them (the owner
sees them by title); otherwise `"any"` and the owner picks.

---

## 3. Poll for approval

```http
GET /v1/access-requests/{request_id}
```

every 3s (no faster than every 2s) until `status` is not `pending`. The request expires after
`15:00`; if you get `expired`, tell your operator and create a new one.

On `approved`, the response contains `token`, your `grant` (which may be narrower than you
asked — read `grant.scopes` and `grant.effective_chat_ids`), and `webhook.secret` if you
registered a webhook. **Persist `token` and `webhook.secret` immediately**: they are shown
for `10:00` after approval and never again ([grants.md](grants.md#token-storage-for-apps)).

From now on, every request carries:

```
Authorization: Bearer tgw_…
```

Confirm with `GET /v1/me`, which returns your grant, and `GET /v1/chats` (needs `chats:read`)
to see the chats by title.

---

## 4. Choose WebSocket or webhooks

You can use both on one grant; they have independent cursors. Pick one to start.

| | WebSocket (`GET /v1/events/stream`) | Webhooks (gateway POSTs to you) |
|---|---|---|
| Where your app runs | Same Mac as the gateway (the API is loopback-only). | Anywhere reachable over HTTPS from the Mac. |
| Who keeps the cursor | **You.** Pass `since` on connect; persist after processing. | **The gateway.** Advances when you answer `2xx`. |
| Latency | Lowest: events are pushed as recorded. | Up to 500 ms batching, plus your HTTP round trip. |
| When you are down | Nothing happens; you replay from `since` when back. | Gateway retries for `24:00:00` then pauses; resume from the gateway or your side. |
| Ordering | In `seq` order per connection. | In `seq` order per grant; one delivery in flight at a time. |
| Duplicates | On reconnect before you persisted the cursor. | On lost `2xx` and on gateway restart. |
| You need to build | A reconnect loop and a cursor file. | An HTTPS endpoint, signature verification, idempotent handling. |
| Backfill of old events | `GET /v1/events?since=` yourself. | Cursor starts at the head when the webhook is created; pull older events with `GET /v1/events` once. |
| Good for | Local services, CLIs, anything on the Mac; development. | Servers elsewhere, serverless functions, anything that must not hold a socket. |

Rule of thumb: on the Mac, WebSocket; anywhere else, webhooks.

Both deliver **at least once, in order**. Dedupe on `seq` either way (step 8).

---

## 5. Connect and resume with `since`

`since` is exclusive: you get events with `seq` **greater than** it. Store the `seq` of the
last event you fully processed; that is exactly the value to send next time.

First run, you have no cursor. Decide:

- **Only new events**: open the WebSocket without `since`. The first frame is `caught_up`
  with the current head; store that `seq` as your cursor.
- **Everything retained**: `since=0`. The gateway keeps all events unless the owner prunes.
  The backlog can be large; it is streamed in order and then `caught_up` follows.
- **From a known point**: `since=<seq>`.

For webhooks there is no `since`: the gateway starts your cursor at the head when the webhook
is registered. To get older events, call `GET /v1/events?since=0&limit=1000` in a loop
(follow `next_since` while `has_more`) before or after registering; dedupe on `seq` covers
any overlap.

If `since` is older than what the gateway still holds you get `410 history_pruned` (HTTP) or
an error frame then close `4410` (WebSocket) with `details.oldest_seq`. Log the gap, set your
cursor to `oldest_seq`, and if the gap matters, fill it from history (step 9).

Paged reads without a socket, for batch jobs:

```http
GET /v1/events?since=4700&limit=1000
```

```json
{ "events": [ … ], "has_more": true, "next_since": 5700, "head_seq": 9100 }
```

Loop until `has_more` is false. `head_seq - next_since` tells you how far behind you are.

---

## 6. Handle heartbeat and reconnect

Frames on the WebSocket ([api.md](api.md#get-v1eventsstream-websocket)):

```json
{ "type": "event", "event": { "seq": 4810, … } }
{ "type": "caught_up", "seq": 4812 }
{ "type": "heartbeat", "seq": 4812, "time": "2026-09-29T14:03:37.001Z" }
{ "type": "error", "code": "history_pruned", "message": "…", "details": { "oldest_seq": 4000 } }
```

The gateway sends a heartbeat every 30s of silence. Your rule: **if no frame of any kind
arrives for `01:30`, the connection is dead** — close it and reconnect. Reconnect with your
persisted cursor as `since`. Back off: 1s, 2s, 4s, … capped at 30s, with jitter, because a
gateway restart (`close 1001`) brings every local consumer back at the same moment.

Close codes to special-case: `4499` (your grant was revoked — stop, alert a human), `4410`
(history pruned — see step 5), `4409` (too many connections from this token — you have a
leak; do not reconnect blindly). Everything else: reconnect.

Ignore frames whose `type` you do not know, and events whose `event.type` you do not know;
the format grows additively ([events.md](events.md#versioning)).

---

## 7. Verify webhook signatures

Each delivery carries `X-TGW-Signature: sha256=<hex>`, the HMAC-SHA256 of the **raw request
body bytes** keyed with your webhook secret. Verify before you parse the JSON, using the
exact bytes received (not a re-serialisation), with a constant-time comparison. Reject with
`401` on mismatch and do not process.

TypeScript (Node 22, built-in `crypto`):

```ts
import { createHmac, timingSafeEqual } from "node:crypto";

export function verifyTgwSignature(rawBody: Buffer, header: string | undefined, secret: string): boolean {
  if (!header?.startsWith("sha256=")) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  const given = Buffer.from(header.slice("sha256=".length), "hex");
  return given.length === expected.length && timingSafeEqual(given, expected);
}
```

Python 3.12:

```python
import hmac, hashlib

def verify_tgw_signature(raw_body: bytes, header: str | None, secret: str) -> bool:
    if not header or not header.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(header[len("sha256="):], expected)
```

Make sure your framework gives you the raw body: in Express use `express.raw({ type:
"application/json" })` on that route, not `express.json()`; in FastAPI `await request.body()`.

Then: process the batch (`body.events`, in order), and answer `2xx` **within 10s**. If
processing may take longer, persist the batch and answer `200` first; the gateway does not
care what you did, only that you accepted it. Answer `410` if you want the gateway to pause
deliveries to you.

---

## 8. Dedupe on `seq`

Both channels are at-least-once. Every event's `seq` is unique and strictly increasing in
what you receive, so deduplication is one comparison:

```
if event.seq <= cursor: skip
else: process(event); cursor = event.seq; persist(cursor)
```

Persist the cursor **after** processing, so a crash between the two replays the event rather
than losing it. If processing is not idempotent (you increment a counter), make the two
atomic: write the counter and the cursor in the same transaction, or keep the counter keyed
by `seq` and let the write be a no-op on repeat.

`seq` is global to the gateway, so your app sees gaps. A gap is not a lost event; only a
`seq` you already processed appearing again is a duplicate.

---

## 9. Read history for backfilling

Events start when the owner began monitoring a chat. For anything earlier — last quarter's
messages for an analytics baseline — use history, which reads the chat's timeline from
Telegram itself (needs `history:read`):

```http
GET /v1/chats/-1001234567890/messages?limit=100
```

returns the 100 newest messages, newest first, in the same [message object](events.md#message-object)
shape as `message.new`, plus `next_before`. Loop:

```
before = None
while True:
    page = GET /v1/chats/{id}/messages?limit=100[&before=before]
    for m in page.messages: upsert(m)      # keyed by (chat_id, id)
    if not page.has_more: break
    before = page.next_before
    sleep as needed: 60 requests per minute
```

Stop when you reach the date you care about. Key your storage by `(chat_id, message.id)`,
not by `seq` (history has no `seq`), and let `message.new` / `message.edited` events upsert
into the same table so the two sources merge cleanly. Do the backfill once per chat and
record that you did; run it again for a chat when you see `monitoring.started` for it.

---

## 10. Fetch media

A message's `media[0].media_id` (if any) is fetched with `media:read`:

```http
GET /v1/media/med_3fK9pQ2mR7tV1wX5yZ8aB4cD6eF0gH2j
```

- `200`: the bytes, with `Content-Type` and `Content-Disposition`. Store them under your own
  key; the response is `immutable`, so you never need to fetch the same `media_id` twice.
- `202` with `Retry-After: 5`: the gateway is still downloading from Telegram (large video).
  Wait and repeat; each call blocks up to 30s while the download progresses.
- `410 media_gone`: Telegram no longer serves the file; record that and move on.
- `403 chat_not_granted`: the media belongs to a chat outside your grant.

At most 4 uncached downloads per token run concurrently; queue the rest. Fetch lazily —
photos in a busy channel add up — and only the kinds you use (`kind` in the media object).

---

## 11. A minimal complete WebSocket consumer

Node 22, TypeScript, one dependency (`ws`). It persists its cursor to a file, resumes with
`since`, reconnects with backoff, treats `01:30` of silence as dead, dedupes on `seq`, and
stops on revocation. `TGW_TOKEN` in the environment; `TGW_URL` optional.

```ts
// consumer.ts — run with: pnpm add ws @types/ws && pnpm dlx tsx consumer.ts
import WebSocket from "ws";
import { readFile, writeFile, rename } from "node:fs/promises";

const BASE = process.env.TGW_URL ?? "http://127.0.0.1:41414";
const TOKEN = process.env.TGW_TOKEN ?? (() => { throw new Error("TGW_TOKEN is required"); })();
const CURSOR_FILE = process.env.TGW_CURSOR_FILE ?? "./tgw.cursor";
const DEAD_AFTER_MS = 90_000; // 01:30 without any frame

type GatewayEvent = { v: number; seq: number; type: string; [k: string]: unknown };
type EventFrame = { type: "event"; event: GatewayEvent };
type Frame =
  | EventFrame
  | { type: "caught_up"; seq: number }
  | { type: "heartbeat"; seq: number; time: string }
  | { type: "error"; code: string; message: string; details?: { oldest_seq?: number } };
// Frames of a type not listed here reach the `default` branch below and are ignored.

async function loadCursor(): Promise<number | null> {
  try { return Number(await readFile(CURSOR_FILE, "utf8")) || null; } catch { return null; }
}

async function saveCursor(seq: number): Promise<void> {
  await writeFile(`${CURSOR_FILE}.tmp`, String(seq), "utf8");
  await rename(`${CURSOR_FILE}.tmp`, CURSOR_FILE); // atomic replace
}

// Replace with your own work. Must be safe to call twice with the same event.
async function handle(frame: EventFrame): Promise<void> {
  const e = frame.event;
  if (e.type === "message.new") {
    const msg = e.message as { chat_id: string; id: string; text: string };
    console.log(`#${e.seq} ${msg.chat_id}/${msg.id}: ${msg.text.slice(0, 80)}`);
  }
  // Unknown event types are ignored on purpose (additive format).
}

function connectOnce(cursor: number | null): Promise<"reconnect" | "stop"> {
  return new Promise((resolve) => {
    const url = new URL("/v1/events/stream", BASE.replace(/^http/, "ws"));
    if (cursor !== null) url.searchParams.set("since", String(cursor));

    const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${TOKEN}` } });
    let last = cursor ?? 0;
    let queue: Promise<void> = Promise.resolve(); // process frames strictly in order
    let deadTimer: NodeJS.Timeout | undefined;
    const alive = () => {
      clearTimeout(deadTimer);
      deadTimer = setTimeout(() => { console.error("no frames for 01:30, reconnecting"); ws.terminate(); }, DEAD_AFTER_MS);
    };

    ws.on("open", () => { console.error(`connected, since=${cursor ?? "(live)"}`); alive(); });

    ws.on("message", (data) => {
      alive();
      const frame = JSON.parse(data.toString()) as Frame;
      queue = queue.then(async () => {
        switch (frame.type) {
          case "event":
            if (frame.event.seq <= last) return;      // duplicate after a reconnect
            await handle(frame);
            last = frame.event.seq;
            await saveCursor(last);                   // persist AFTER processing
            return;
          case "caught_up":
            if (cursor === null) { last = frame.seq; await saveCursor(last); } // live-only start
            console.error(`caught up at seq ${frame.seq}`);
            return;
          case "heartbeat":
            return;
          case "error":
            console.error(`gateway error ${frame.code}: ${frame.message}`);
            if (frame.code === "history_pruned" && frame.details?.oldest_seq) {
              last = frame.details.oldest_seq; await saveCursor(last); // accept the gap
            }
            return;
          default:
            return; // unknown frame type: ignore
        }
      }).catch((err) => { console.error("handler failed, reconnecting", err); ws.terminate(); });
    });

    ws.on("close", (code) => {
      clearTimeout(deadTimer);
      queue.finally(() => {
        if (code === 4499) { console.error("grant revoked; stopping"); resolve("stop"); return; }
        if (code === 4409) { console.error("too many connections for this token; stopping"); resolve("stop"); return; }
        console.error(`closed (${code})`);
        resolve("reconnect");
      });
    });

    ws.on("error", (err) => console.error("socket error", err.message));
  });
}

async function main(): Promise<void> {
  let backoffMs = 1000;
  for (;;) {
    const cursor = await loadCursor();
    const startedAt = Date.now();
    const outcome = await connectOnce(cursor);
    if (outcome === "stop") process.exit(1);
    if (Date.now() - startedAt > 60_000) backoffMs = 1000; // it was healthy for a while
    const jitter = Math.random() * backoffMs;
    await new Promise((r) => setTimeout(r, backoffMs + jitter));
    backoffMs = Math.min(backoffMs * 2, 30_000);
  }
}

main().catch((err) => { console.error(err); process.exit(1); });
```

What it does not do, and you should: verify `GET /v1/me` at start and after `monitoring.*`
events to know current coverage; handle `SIGTERM` by letting the in-flight handler finish
before exit (the cursor is only written after a handler completes, so a hard kill is still
safe — the event replays).

---

## 12. Your integration is correct when…

- [ ] It requests only the scopes it uses, with a description the owner can understand.
- [ ] It persists the token and webhook secret the instant it sees `status: "approved"`.
- [ ] It reads `grant.effective_chat_ids` and `grant.scopes` from the gateway rather than
      assuming what it asked for.
- [ ] It stores the last processed `seq` and sends it as `since` (WebSocket) — after
      processing, atomically with any non-idempotent side effect.
- [ ] Killing it at any moment and restarting loses no event and double-counts none.
- [ ] It ignores `seq` values it has already processed, on both channels.
- [ ] It treats `01:30` without frames as a dead connection and reconnects with backoff.
- [ ] It stops and alerts on close code `4499` / `401 token_revoked`, and handles
      `history_pruned` by moving to `oldest_seq` and backfilling from history if needed.
- [ ] Webhook endpoint: verifies `X-TGW-Signature` against the raw body with a constant-time
      compare, answers `2xx` within 10s, is idempotent per `seq`.
- [ ] It ignores unknown fields, unknown event types, and unknown enumeration values.
- [ ] It compares ids as strings and never parses them as numbers.
- [ ] Entity offsets are treated as UTF-16 code units.
- [ ] History backfill is keyed by `(chat_id, message.id)` and merges with live events.
- [ ] Media is fetched at most once per `media_id`, handling `202` and `410`.
- [ ] It re-reads `GET /v1/me` after `monitoring.started` / `monitoring.stopped` and
      backfills a newly covered chat if it needs the past.
- [ ] Nothing it logs contains the token or the webhook secret.
