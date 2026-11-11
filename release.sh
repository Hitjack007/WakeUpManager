#!/bin/bash
set -euo pipefail

# Usage: ./release.sh <version> "<notes>"
# e.g.   ./release.sh 1.0.1 "Wake log reads the real history, settings are saved by the agent"
#
# Archives the app, wraps it in a DMG, signs it for Sparkle, adds it to docs/appcast.xml (served by
# GitHub Pages, which is where installed copies look for updates) and publishes a GitHub release.
# Run it from the main branch: the appcast is only served from there.
# Set DRY_RUN=1 to stop after the DMG and its signature: nothing is committed, tagged or published (the
# version is bumped only in a throwaway copy of the project file and restored afterwards).
#
# The app is signed with the project's development team, like the build you run from Xcode. A Mac other
# than yours will refuse to open it until it is signed with a Developer ID certificate and notarized.

VERSION="${1:?Usage: ./release.sh <version> \"<release notes>\"}"
NOTES="${2:?Please provide release notes as the second argument}"
DRY_RUN="${DRY_RUN:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/WakeUpManager.xcodeproj"
PROJECT_FILE="$PROJECT_DIR/project.xcproj"
SCHEME="WakeUpManager"
APP_NAME="WakeUpManager"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ARCHIVE_PATH="/tmp/${APP_NAME}-${VERSION}.xcarchive"
DMG_PATH="/tmp/${DMG_NAME}"
BUILD_NUM=$(date +%Y%m%d%H%M)
APPCAST="$SCRIPT_DIR/docs/appcast.xml"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WakeUp Manager release script v${VERSION}$([ "$DRY_RUN" = 1 ] && echo " (dry run)")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Preflight checks ────────────────────────────────────────────────────────

echo "→ Checking dependencies..."

if ! command -v gh &>/dev/null; then
    echo "Error: GitHub CLI (gh) not found. Install with: brew install gh"
    exit 1
fi

if ! command -v create-dmg &>/dev/null; then
    echo "Error: create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/sparkle/*" 2>/dev/null | head -1)
if [ -z "$SPARKLE_BIN" ]; then
    echo "Error: Sparkle sign_update not found. Open the project in Xcode once to resolve packages."
    exit 1
fi
echo "  sign_update: $SPARKLE_BIN"

if [ "$DRY_RUN" != 1 ] && [ "$(git -C "$SCRIPT_DIR" branch --show-current)" != "main" ]; then
    echo "Error: Releases are made from the main branch (GitHub Pages serves the appcast from there)."
    exit 1
fi

# Uncommitted changes would be left out of the release but still bumped into it. Untracked files are fine.
if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no)" ]; then
    echo "Error: You have uncommitted changes. Commit or stash them before releasing."
    exit 1
fi

# ── Bump version in the Xcode project ───────────────────────────────────────

echo ""
echo "→ Bumping version to ${VERSION} (build ${BUILD_NUM})..."
cp "$PROJECT_FILE" "/tmp/${APP_NAME}-project.xcproj.orig"
restore_project() {
    # A dry run never keeps the bump.
    if [ "$DRY_RUN" = 1 ]; then cp "/tmp/${APP_NAME}-project.xcproj.orig" "$PROJECT_FILE"; fi
}
trap restore_project EXIT

sed -i '' -E \
    -e "s/(\"MARKETING_VERSION\": \")[^\"]*\"/\1${VERSION}\"/" \
    -e "s/(\"CURRENT_PROJECT_VERSION\": \")[^\"]*\"/\1${BUILD_NUM}\"/" \
    "$PROJECT_FILE"
if ! grep -q "\"MARKETING_VERSION\": \"${VERSION}\"" "$PROJECT_FILE"; then
    echo "Error: Could not set MARKETING_VERSION in the project file."
    exit 1
fi
echo "  MARKETING_VERSION = ${VERSION}"
echo "  CURRENT_PROJECT_VERSION = ${BUILD_NUM}"

# ── Commit version bump ──────────────────────────────────────────────────────

if [ "$DRY_RUN" != 1 ]; then
    echo ""
    echo "→ Committing version bump..."
    cd "$SCRIPT_DIR"
    git add "$PROJECT_FILE"
    git commit -m "Bump version to ${VERSION}"
fi

# ── Resolve minimum supported macOS version ─────────────────────────────────

echo ""
echo "→ Resolving minimum macOS version from build settings..."
MIN_OS_VERSION=$(xcodebuild -showBuildSettings \
    -project "$PROJECT_DIR" \
    -scheme "$SCHEME" \
    -configuration Release 2>/dev/null \
    | awk -F '= ' '$1 ~ /^[[:space:]]*MACOSX_DEPLOYMENT_TARGET[[:space:]]*$/ { print $2; exit }')

if [ -z "$MIN_OS_VERSION" ]; then
    echo "Error: Could not resolve MACOSX_DEPLOYMENT_TARGET from build settings."
    exit 1
fi
echo "  Minimum macOS version: $MIN_OS_VERSION"

# ── Archive ──────────────────────────────────────────────────────────────────
# The "Embed scheduler programs" build phase runs here too, so the archive contains the agent, the root
# helper and the wakeup tool, signed with the same identity as the app.

echo ""
echo "→ Archiving (this takes a few minutes: it builds the scheduler package in release mode)..."
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
    -project "$PROJECT_DIR" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    SKIP_INSTALL=NO \
    2>&1 | grep -E "^(error:|.*error:|Build succeeded|\*\* ARCHIVE)" || true

APP_PATH=$(find "$ARCHIVE_PATH/Products" -name "*.app" -maxdepth 3 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    echo "Error: No .app found in archive. Check Xcode signing settings."
    exit 1
fi
echo "  App: $APP_PATH"

echo ""
echo "→ Checking the scheduler programs are inside the app..."
for item in \
    "Contents/Helpers/wakeup-agent" \
    "Contents/Helpers/wakeup-helper" \
    "Contents/Helpers/wakeup" \
    "Contents/Library/LaunchAgents/com.wakeupmanager.agent.plist" \
    "Contents/Library/LaunchDaemons/com.wakeupmanager.helper.plist"; do
    if [ ! -e "$APP_PATH/$item" ]; then
        echo "Error: $item is missing from the archive. Is the \"Embed scheduler programs\" build phase on the target?"
        exit 1
    fi
done
codesign --verify --deep --strict "$APP_PATH"
echo "  All present, signature verifies."

# ── DMG ──────────────────────────────────────────────────────────────────────

echo ""
echo "→ Creating DMG..."
rm -f "$DMG_PATH"
STAGING="/tmp/${APP_NAME}-staging-$$"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"

create-dmg \
    --volname "WakeUp Manager" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 180 185 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 480 185 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGING/" 2>&1 | grep -v "^$" || true

rm -rf "$STAGING"
if [ ! -f "$DMG_PATH" ]; then
    echo "Error: the DMG was not created."
    exit 1
fi
echo "  Created: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"

# ── Sparkle signing ───────────────────────────────────────────────────────────
# The private key lives in the login keychain (made by Sparkle's generate_keys). Installed copies check
# this signature against SUPublicEDKey in the app's Info.plist before they install anything.

echo ""
echo "→ Signing DMG with Sparkle..."
SIGN_OUTPUT=$("$SPARKLE_BIN" "$DMG_PATH" 2>&1)
ED_SIG=$(echo "$SIGN_OUTPUT" | grep -oE 'edSignature="[^"]+"' | head -1 | cut -d'"' -f2)
FILE_LEN=$(echo "$SIGN_OUTPUT" | grep -oE 'length="[0-9]+"' | head -1 | cut -d'"' -f2)

if [ -z "$ED_SIG" ] || [ -z "$FILE_LEN" ]; then
    echo "Error: Could not parse Sparkle signature. Output was:"
    echo "$SIGN_OUTPUT"
    exit 1
fi
echo "  edSignature: ${ED_SIG:0:20}..."
echo "  length: $FILE_LEN"

if [ "$DRY_RUN" = 1 ]; then
    echo ""
    echo "Dry run finished. Nothing was committed or published."
    exit 0
fi

# ── Update appcast.xml ────────────────────────────────────────────────────────

echo ""
echo "→ Updating appcast.xml..."
RELEASE_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
REPO_URL=$(gh repo view --json url --jq .url)
DOWNLOAD_URL="${REPO_URL}/releases/download/v${VERSION}/${DMG_NAME}"

ITEM_FILE="/tmp/${APP_NAME}-appcast-item.xml"
cat > "$ITEM_FILE" <<ITEMEOF

    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${RELEASE_DATE}</pubDate>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS_VERSION}</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${ED_SIG}"
        length="${FILE_LEN}"
        type="application/octet-stream"/>
    </item>
ITEMEOF

# Put the new item just before the closing tag of the channel.
awk -v itemfile="$ITEM_FILE" '
    /<\/channel>/ && !done { while ((getline line < itemfile) > 0) print line; print ""; done = 1 }
    { print }
' "$APPCAST" > "$APPCAST.new"
mv "$APPCAST.new" "$APPCAST"
rm -f "$ITEM_FILE"
echo "  Added v${VERSION} entry"

# ── GitHub release ───────────────────────────────────────────────────────────

echo ""
echo "→ Creating GitHub release v${VERSION}..."
cd "$SCRIPT_DIR"
git push
gh release create "v${VERSION}" "$DMG_PATH" \
    --title "WakeUp Manager v${VERSION}" \
    --notes "$NOTES"

echo ""
echo "→ Publishing the appcast..."
git add docs/appcast.xml
git commit -m "Release v${VERSION}"
git push

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  v${VERSION} shipped!"
echo "  ${REPO_URL}/releases/tag/v${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
