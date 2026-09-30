#!/bin/sh
# Renders every state of the menu bar popover and the main window into PNG files.
#
#   App/snapshot.sh <output directory> [--key] [--only <prefix>]
#
# The app (a Debug build) steps through its states with the fake gateway. Popover and sheet
# states are rendered by the app itself; main-window states are photographed from here with
# `screencapture -l <window id>`, because an in-process render cannot see the sidebar. That
# needs Screen Recording permission for the terminal running this script.
#
#   --key   make each snapshot window the key window of the frontmost app, so native controls
#           are drawn in the accent colour as the owner sees them. The app is then launched
#           through LaunchServices (`open`), because macOS only lets a launched app come to
#           the front, not a binary started from a shell. It takes keyboard focus while it
#           runs. Without --key, native controls are drawn grey, as in any inactive window.
#
# APP_BIN overrides the binary (default: the build made by App/run.sh). Nothing here touches
# the Keychain, launchd, config.json or the app's saved state.
set -eu

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${APP_BIN:-$APP_DIR/.derived/Build/Products/Debug/TelegramGateway.app/Contents/MacOS/TelegramGateway}"
[ $# -ge 1 ] || { echo "usage: $0 <output directory> [--key] [--only <prefix>]" >&2; exit 2; }
DIR="$1"; shift
[ -x "$BIN" ] || { echo "no app binary at $BIN (run App/run.sh --no-launch, or set APP_BIN)" >&2; exit 1; }

mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
rm -f "$DIR/.shoot" "$DIR/.log"

KEY=0
for arg in "$@"; do [ "$arg" = "--key" ] && KEY=1; done

if [ "$KEY" = 1 ]; then
	open -n -W "${BIN%/Contents/MacOS/*}" --stdout "$DIR/.log" --stderr /dev/null --args --snapshot "$DIR" --shoot "$@" &
else
	"$BIN" --snapshot "$DIR" --shoot "$@" > "$DIR/.log" 2>/dev/null &
fi
PID=$!
while kill -0 "$PID" 2>/dev/null; do
	if [ -f "$DIR/.shoot" ]; then
		read -r WINDOW NAME < "$DIR/.shoot"
		screencapture -x -o -l"$WINDOW" "$DIR/$NAME"
		rm -f "$DIR/.shoot"
	else
		sleep 0.05
	fi
done
wait "$PID" || true
if ! grep -q "snapshots written" "$DIR/.log" 2>/dev/null; then
	rm -f "$DIR/.log"
	echo "the snapshot run ended early (the app quit or was quit before the last state)" >&2
	exit 1
fi
rm -f "$DIR/.log"
echo "snapshots in $DIR: $(ls "$DIR" | wc -l | tr -d ' ') files"
