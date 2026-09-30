#!/bin/sh
# Builds the menu bar app (Debug, ad-hoc signed) and launches it.
#
#   App/run.sh            build and launch
#   App/run.sh --test     run the unit tests instead
#   App/run.sh --no-launch  build only
#
# The app is built into App/.derived so it lives inside the repository: the app then finds
# <repo>/.build/debug/GatewayDaemon (from `swift build`) by walking up from its own location,
# in addition to the $(SRCROOT)-derived path baked into its Info.plist.
set -eu

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$APP_DIR/.derived"
PROJECT="$APP_DIR/TelegramGateway.xcodeproj"
SCHEME="TelegramGateway"
ACTION="build"
LAUNCH=1

for arg in "$@"; do
	case "$arg" in
		--test) ACTION="test"; LAUNCH=0 ;;
		--no-launch) LAUNCH=0 ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

if [ "$ACTION" = "test" ]; then
	exec xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -derivedDataPath "$DERIVED" -destination 'platform=macOS' test
fi

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -derivedDataPath "$DERIVED" -destination 'platform=macOS' build | grep -E '^(error|warning|\*\*)|error:' || true

APP="$DERIVED/Build/Products/Debug/TelegramGateway.app"
if [ ! -d "$APP" ]; then
	echo "build failed: $APP not found" >&2
	exit 1
fi
echo "built $APP"

if [ "$LAUNCH" = 1 ]; then
	# A running copy keeps its old code; replace it.
	pkill -x TelegramGateway 2>/dev/null || true
	open "$APP"
	echo "launched; look for the paper-plane icon in the menu bar"
fi
