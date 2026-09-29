# Grants: the access model

This document explains, in plain words, who can see what through the gateway. The endpoints
are in [api.md](api.md); the event format in [events.md](events.md).

## Contents

- [Two sets: monitored and granted](#two-sets-monitored-and-granted)
- [Scopes](#scopes)
- [Folder-based grants](#folder-based-grants)
- [Requesting access and what the owner sees](#requesting-access-and-what-the-owner-sees)
- [Tokens](#tokens)
- [Revocation](#revocation)
- [Token storage for apps](#token-storage-for-apps)
- [Privacy principles](#privacy-principles)

---

## Two sets: monitored and granted

The gateway is logged in as the owner's own Telegram user, so it *could* see everything that
user sees: every private conversation, every group, every channel. It deliberately does not
store or forward most of it. Two sets decide what an application receives:

**Monitored chats** — the chats the gateway watches at all. The owner chooses them in the menu
bar app (or with `tgw`). Only messages in monitored chats are written to the gateway's event
log; messages in any other chat are seen by TDLib in memory and discarded. This set is
global: it does not belong to any application.

**Granted chats** — per application, the subset of chats that application may read. A
**grant** is the record of one application's access: its name, its scopes, its chats, its
token. The owner creates a grant by approving an access request and can narrow it to fewer
chats and fewer scopes than the application asked for.

The rule that ties them together:

> **A grant never exceeds the monitored set.** What an application can see right now is
> `granted chats ∩ monitored chats`, computed whenever the application asks.

The API calls that intersection `effective_chat_ids` (in the grant object returned by
`GET /v1/me`). Consequences:

- If the owner stops monitoring a chat, every grant that included it loses it at once, with
  a `monitoring.stopped` event to the applications that had it. The grant still lists the
  chat, so if the owner monitors it again, access resumes without a new approval.
- Approving a request for a chat that is not monitored fails (`400 chat_not_monitored`). The
  menu bar app handles this by offering to monitor the chat as part of the approval, so the
  owner experiences one decision, not two.
- An application cannot learn that an unmonitored or ungranted chat exists: asking about it
  returns the same `403 chat_not_granted` as asking about a chat id that was never real.

```
 all chats the owner's account can see
 ┌───────────────────────────────────────────────┐
 │  monitored (owner's choice, global)           │
 │  ┌─────────────────────────┐                  │
 │  │ granted to app A        │                  │
 │  │ ┌──────────┐            │  granted to app B│
 │  │ │ effective│            │  ┌────────────┐  │
 │  │ │ for A    │            │  │ effective  │  │
 │  │ └──────────┘            │  │ for B      │  │
 │  └─────────────────────────┘  └────────────┘  │
 └───────────────────────────────────────────────┘
   private chats, unmonitored groups: never stored, never delivered
```

---

## Scopes

A **scope** names a kind of access. A grant holds one or more. Scopes control *what kind of
data*; the chat set controls *from where*. Both apply to every request.

| Scope | Allows | Endpoints and events |
|---|---|---|
| `messages:read` | Receive messages as they arrive, and read the stored backlog. | `message.new`, `message.edited`, `message.deleted` events on `GET /v1/events` and the WebSocket. |
| `history:read` | Read a chat's timeline from Telegram, back before the gateway monitored it. | `GET /v1/chats/{chat_id}/messages`. |
| `media:read` | Download files referenced by messages and chat photos. | `GET /v1/media/{media_id}`. Without it, messages still carry media objects (name, size, kind); only the bytes are withheld. |
| `chats:read` | List the granted chats with title, username, member count; learn when coverage changes. | `GET /v1/chats`, `chat.updated`, `monitoring.started`, `monitoring.stopped`. |
| `messages:send` | **Reserved. Not implemented in v1.** Requesting it fails with `400 scope_not_available`. | — |

`GET /v1/me` and the webhook endpoints under `/v1/me/webhook` need no particular scope — any
valid app token can inspect and manage its own grant.

Typical combinations:

| Application | Scopes |
|---|---|
| Live classifier / alerting | `messages:read`, `chats:read` |
| Analytics with backfill of past months | `messages:read`, `history:read`, `chats:read` |
| Archive with attachments | `messages:read`, `history:read`, `media:read`, `chats:read` |

Ask for the least you need. The owner sees the scopes when approving, and a request for
`media:read` from something that only counts hashtags looks wrong.

---

## Folder-based grants

A Telegram **folder** (Telegram calls them "chat folders"; they appear as tabs at the top of
the chat list on the phone and desktop) is a named collection of chats the owner maintains in
their normal Telegram apps: "Work", "Crypto", "Product". The gateway reads the owner's
folders through TDLib.

A grant's chats can be either a fixed **list** of chat ids, or a **folder**. With a folder
grant, the granted set is "whatever is in that folder at the time of the request" — when the
owner drags a new channel into the "Product" folder on their phone, every application with a
grant on "Product" gains that channel without another approval round, and when a chat is
removed from the folder, access ends.

The monitored set can also follow a folder (`folder_ids` in `PUT /v1/admin/monitored-chats`).
The usual arrangement is: the owner monitors the "Product" folder, and grants applications
the "Product" folder. Then "add a channel to the folder on the phone" is the whole workflow
for extending both monitoring and access. If a folder is granted but not monitored, the rule
above still applies: the effective set is the folder's chats that are monitored, and the
menu bar app warns about it at approval time.

An application cannot ask for a folder by name; it asks for chats or `"any"`, and the owner
chooses to answer with a folder. The application sees which in `GET /v1/me`:
`"chats": { "mode": "folder", "folder_id": "3", "folder_title": "Product" }`.

---

## Requesting access and what the owner sees

The application calls `POST /v1/access-requests` with a name, a description, scopes, and
optionally the chats it would like (see [api.md](api.md#access-requests)). The request is
**pending** for `15:00`. In the menu bar app the owner sees:

```
Community Analytics wants access
"Classifies messages in product channels and counts topics per day."

Scopes         messages:read   history:read   chats:read
Requested      Acme Product Updates          (monitored)
               Acme Support                  (not monitored — will be monitored)
Webhook        https://analytics.example.com/tgw/events

Chats to grant [ list: Acme Product Updates, Acme Support ]  or  [ folder: Product ▾ ]
Scopes to grant [x] messages:read  [x] history:read  [ ] chats:read

                                        [ Deny ]   [ Approve ]
```

The owner may remove scopes and change the chat set freely (narrowing or widening within the
monitored set), and may switch to a folder. What the owner approves is what the grant holds,
so the application must read its grant (`grant` in the poll response, later `GET /v1/me`)
rather than assume its request was honoured as written.

The owner is the only party who can approve. There is no self-approval path, no token
minted from the CLI without the admin token, and no way for an application to widen its own
grant. Asking for more means a new access request, which the owner sees as a new card.

---

## Tokens

A token is the string `tgw_` + 43 characters (32 random bytes, base64url). It is the only
thing an application presents; it identifies the grant and proves possession. The gateway
stores a SHA-256 hash of it, so the token appears exactly once: in the approved poll response
(for `10:00` after approval, then never again).

There is also one **admin token**, held by the menu bar app and `tgw`, that is not tied to a
grant and can do everything. Applications never receive it. The daemon writes it to the
login Keychain, which is why the daemon runs as the owner's user (a LaunchAgent) and not as a
system daemon.

Tokens do not expire. Access ends by revocation.

---

## Revocation

The owner revokes a grant in one click in the menu bar app (`DELETE /v1/admin/grants/{id}`
underneath). Immediately and permanently:

| Channel | Effect |
|---|---|
| HTTP requests | `401 token_revoked` with `details.revoked_at`. |
| Open WebSockets | Closed with code `4499`. Reconnecting fails at the upgrade with `401`. |
| Webhook | No further deliveries; pending deliveries and the cursor are dropped. Any delivery already in flight is not cancelled, so one more batch may land. |
| Media downloads in progress | Aborted. |
| The event log | Untouched; the gateway keeps its own record. The application never had a copy of anything it had not already received. |

There is no un-revoke. The application requests access again, the owner approves again, and a
new grant with a new token is created; a new webhook cursor starts at the head, so a
re-approved application should pull the gap with `GET /v1/events?since=` from its last
processed `seq` (if that history is still retained) or with `history:read`.

Narrowing a grant is not a v1 operation (revoke and re-approve instead); narrowing
*monitoring* is, and takes effect on every grant as described above.

---

## Token storage for apps

- Store the token the moment the poll returns `approved`; the gateway shows it for `10:00`
  and then never again. Write it before you do anything else with it.
- Store it the way you store any secret: a secrets manager, an environment variable set from
  one, or a file with mode `0600` outside the repository. The token grants read access to
  the owner's chosen chats; treat a leak as the owner's data leaking.
- Store the webhook secret alongside it; without it you cannot verify deliveries, and the
  only way to get a new one is `PUT /v1/me/webhook`, which invalidates the old one.
- Store your cursor (last processed `seq`) next to them; it is what makes restarts lossless
  ([integrating.md](integrating.md#connect-and-resume-with-since)).
- On `401 token_revoked`, stop retrying and surface it to a human: only the owner can restore
  access.
- Never log the token. Log `X-TGW-Request-Id` and `error.code`.
- One token per deployment of an application. Two copies of an app sharing a token share a
  grant but keep their own WebSocket cursors (the gateway allows 4 connections); a webhook
  cursor is per grant, so two copies cannot each have their own webhook — request two grants.

---

## Privacy principles

These are commitments of the gateway's design, not configuration:

1. **Nothing unmonitored leaves the gateway.** Messages in chats outside the monitored set
   are never written to disk by the gateway (TDLib keeps its own encrypted cache, which no
   other process can open) and never appear in any API response, including error messages.
2. **Every application sees only its grant.** There is no "list all chats" for an app token,
   no way to probe whether a chat exists, no shared media ids across grants that would let
   one app fetch another app's files (media access is checked against the grant's chats on
   every request).
3. **The gateway never acts as the owner.** It does not send messages, does not mark
   messages as read, does not open chats in a way Telegram counts as viewing, does not set
   the account online, does not join or leave chats. The owner's Telegram apps behave exactly
   as if the gateway did not exist. `messages:send` is reserved precisely so that a future
   decision to change this is explicit.
4. **The owner sees who has what.** Every grant, its scopes, its chats, when it last
   connected, and how many events it received are visible in the menu bar app.
5. **Approval is a human act.** No automation can create or widen a grant; only the admin
   token can approve, and only the menu bar app and `tgw` on the owner's machine hold it.
6. **Revocation is total and immediate.** See above.
7. **Local by default.** The API listens on `127.0.0.1` only. The only outbound traffic to a
   consumer is a webhook the owner approved, to a URL the owner saw at approval time, signed
   so the consumer can verify its origin.
