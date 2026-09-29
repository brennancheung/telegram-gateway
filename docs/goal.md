# Goal

Build a standalone macOS gateway to the owner's own Telegram account so that any project can
receive Telegram messages without building its own Telegram integration, adding bots to
channels, or handling the owner's login.

## Why

- The owner wants to monitor channels and groups for product mentions, support issues and
  industry news, run sentiment analysis, and count what the community is talking about.
- Those are jobs for separate applications. Each of them needs the same thing: a reliable
  stream of messages from chosen chats, as the owner's user (bots cannot be added to every
  channel, and do not see what a user sees).
- Logging in the owner's account is sensitive and should happen exactly once, in one place.
- TDLib's on-disk data cannot be shared between processes, so there must be one owner
  process and everything else must go through it.

## What "done" looks like

The gateway is done when all of the following hold:

1. **It runs on its own.** A launchd LaunchAgent starts the daemon at login and keeps it
   running. Closing the menu bar app does not stop it.
2. **The owner can log in from the menu bar app** by scanning a QR code with their phone
   (with phone number + code + 2FA password as a fallback), and the login survives restarts.
3. **The owner picks which chats are monitored** from their chat list in the menu bar app.
   Nothing that is not monitored ever leaves the gateway.
4. **An application can request access** with a name and scopes, the owner approves it in
   the menu bar app (narrowing it to specific chats), and the application receives a token.
   The owner can revoke it in one click.
5. **An application receives every new message** in the chats it has access to, as events
   in the gateway's own format, over WebSocket or webhooks, and can resume from the last
   event it saw. Messages are not lost when the Mac sleeps, goes offline, or the
   application is down.
6. **An application can read history** for chats it has access to, and download media
   when granted.
7. **The gateway never disturbs the owner's own use of Telegram**: it never marks messages
   as read and never makes the owner appear online.
8. **Everything is documented in this repository** well enough that an agent pointed at the
   repo can build an integration without asking questions.

## Out of scope for the first version

- Sending messages (scope reserved, not implemented).
- Any analytics, classification or sentiment. Consumers do that.
- Consumers on other machines holding a WebSocket to this Mac (webhooks cover remote use).
- Multiple Telegram accounts.
- Linux or Windows.

## First consumer

A small application that receives messages from chosen channels, classifies each one
(product mention / support issue / industry news / other), scores sentiment, and keeps
counts per topic per day. It exists to prove the gateway end to end, and lives in its own
repository.
