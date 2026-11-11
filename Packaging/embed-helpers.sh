#!/bin/sh
# Builds the scheduler's programs from the WakeUpCore package and puts them inside the app:
#
#   Contents/Helpers/wakeup-agent     the scheduler agent (LaunchAgent)
#   Contents/Helpers/wakeup-helper    the root helper (LaunchDaemon)
#   Contents/Helpers/wakeup           the command line tool for scripts and agents
#   Contents/Library/LaunchAgents/    com.wakeupmanager.agent.plist
#   Contents/Library/LaunchDaemons/   com.wakeupmanager.helper.plist
#
# It runs as a Run Script build phase of the WakeUpManager target, before the app is signed, so the app's
# signature covers everything. Each program is signed here with the app's identity and its own identifier,
# because the helper only talks to programs whose identifier and team match.
set -eu

: "${SRCROOT:?run this from the build phase}"
: "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}" "${DEVELOPMENT_TEAM:?Set a development team on the target.}"

CONFIG=release
PACKAGE="$SRCROOT/WakeUpCore"
APP="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"

if [ -z "$IDENTITY" ]; then
  echo "error: no signing identity. The helper only trusts programs signed by your team, so sign the app (Signing & Capabilities)." >&2
  exit 1
fi

# Build with a clean environment: Xcode's own variables (SDKROOT, ARCHS, ...) confuse a nested SwiftPM build.
build() {
  env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    /usr/bin/xcrun swift build -c "$CONFIG" --package-path "$PACKAGE" "$@"
}

for product in wakeup wakeup-agent wakeup-helper; do
  build --product "$product"
done
BIN="$(build --show-bin-path)"

mkdir -p "$APP/Helpers" "$APP/Library/LaunchAgents" "$APP/Library/LaunchDaemons"

install_program() { # name identifier
  cp -f "$BIN/$1" "$APP/Helpers/$1"
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY" --identifier "$2" "$APP/Helpers/$1"
}

install_program wakeup-agent  com.Hitjack007.WakeUpManager.agent
install_program wakeup-helper com.Hitjack007.WakeUpManager.helper
install_program wakeup        com.Hitjack007.WakeUpManager.cli

# The property lists name the team so the agent and helper only trust each other.
sed "s/@TEAM@/$DEVELOPMENT_TEAM/g" "$SRCROOT/Packaging/com.wakeupmanager.agent.plist" \
  > "$APP/Library/LaunchAgents/com.wakeupmanager.agent.plist"
sed "s/@TEAM@/$DEVELOPMENT_TEAM/g" "$SRCROOT/Packaging/com.wakeupmanager.helper.plist" \
  > "$APP/Library/LaunchDaemons/com.wakeupmanager.helper.plist"

echo "Embedded the scheduler programs in $APP"
