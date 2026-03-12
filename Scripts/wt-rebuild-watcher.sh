#!/bin/zsh
# World Tree Staged Rebuild Watcher
# ----------------------------------
# Triggered by launchd WatchPaths when a commit touches the dirty marker.
# Waits for a quiet window (no new commits), then builds to staging,
# atomically swaps into /Applications, and lets launchd restart World Tree.
#
# World Tree stays RUNNING during the entire build. Downtime is only the
# swap+restart (~2 seconds).
#
# Log: ~/.cortana/logs/wt-rebuild.log

set -euo pipefail

PROJECT_DIR="/Users/evanprimeau/Development/WorldTree"
LOG="$HOME/.cortana/logs/wt-rebuild.log"
LOCKFILE="/tmp/wt-rebuild.lock"
DIRTY_FILE="$HOME/.cortana/worldtree/rebuild.dirty"
STAGING_DIR="/tmp/worldtree-staged-build"
APP_NAME="World Tree"
APP_DST="/Applications/${APP_NAME}.app"

QUIET_WINDOW=120   # 2 minutes — no new commits before we build

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

# ── Gate: dirty marker must exist ──
if [ ! -f "$DIRTY_FILE" ]; then
    exit 0
fi

# ── Serialize: one build at a time ──
if ! (set -C; > "$LOCKFILE") 2>/dev/null; then
    echo "=== $(date) Skipping — another build already running ==="
    exit 0
fi
trap "rm -f '$LOCKFILE'" EXIT

echo ""
echo "=== $(date) Rebuild watcher triggered ==="

# ── Wait for quiet window ──
# Sleep until no commits have landed for QUIET_WINDOW seconds.
# Each new commit re-touches the dirty file, resetting the clock.
while true; do
    LAST_MODIFIED=$(stat -f %m "$DIRTY_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$((NOW - LAST_MODIFIED))

    if [ "$AGE" -ge "$QUIET_WINDOW" ]; then
        echo "Quiet window reached (${AGE}s since last commit). Proceeding with build."
        break
    fi

    REMAINING=$((QUIET_WINDOW - AGE))
    echo "Waiting ${REMAINING}s for quiet window..."
    sleep "$REMAINING"
done

cd "$PROJECT_DIR" || { echo "ERROR: Cannot cd to $PROJECT_DIR"; exit 1; }

# ── Skip if Xcode is open (it holds the build DB) ──
if pgrep -x "Xcode" &>/dev/null; then
    echo "Xcode is running — skipping. Press Cmd+R in Xcode to rebuild."
    osascript -e 'display notification "Commits pending rebuild. Press ⌘R in Xcode or close Xcode for auto-build." with title "World Tree" sound name "Pop"' &
    rm -f "$DIRTY_FILE"
    exit 0
fi

# ── Regenerate xcodeproj ──
if command -v xcodegen &>/dev/null; then
    echo "Regenerating .xcodeproj..."
    xcodegen generate --spec project.yml 2>&1 || true
fi

# ── Build to staging (World Tree keeps running) ──
echo "Building to staging dir..."
export WT_STAGED_BUILD=1
/usr/bin/xcodebuild \
    -project "WorldTree.xcodeproj" \
    -scheme "WorldTree" \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$STAGING_DIR" \
    -quiet \
    build

BUILD_EXIT=$?

if [ $BUILD_EXIT -ne 0 ]; then
    echo "Build FAILED (exit $BUILD_EXIT)"
    osascript -e 'display notification "World Tree rebuild FAILED. Check wt-rebuild.log" with title "Build Error" sound name "Basso"' &
    # Don't remove dirty marker — retry on next trigger
    exit 1
fi

echo "Build succeeded. Swapping..."

# ── Atomic swap: kill → copy → re-sign → launchd restarts ──
STAGED_APP="${STAGING_DIR}/Build/Products/Debug/${APP_NAME}.app"

if [ ! -d "$STAGED_APP" ]; then
    echo "ERROR: Staged app not found at $STAGED_APP"
    exit 1
fi

# Graceful shutdown — SIGTERM lets World Tree save state and exit cleanly.
# launchd will restart it after we finish copying.
echo "Sending SIGTERM to ${APP_NAME}..."
killall "${APP_NAME}" 2>/dev/null || true
sleep 1

# Copy staged build to /Applications
echo "Installing to ${APP_DST}..."
ditto "$STAGED_APP" "$APP_DST"

# Re-sign after copy (cross-volume ditto can strip signatures)
# Extract the specific signing identity SHA-1 hash from the staged build.
# "Apple Development" is ambiguous (matches 2+ certs) — must use the hash.
IDENTITY=$(codesign -dvv "$STAGED_APP" 2>&1 | grep "Authority=" | head -1 | sed 's/Authority=//')
SIGN_HASH=$(codesign -dvv "$STAGED_APP" 2>&1 | awk -F= '/^Authority=/{print; exit}')
# Extract the SHA-1 from the staged binary's signature directly
SIGN_HASH=$(security find-identity -v -p codesigning | grep "Apple Development.*6JB5KB6D47" | head -1 | awk '{print $2}')
if [ -z "$SIGN_HASH" ]; then
    echo "WARNING: Could not find signing identity — falling back to first Apple Development cert"
    SIGN_HASH=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
fi

ENTITLEMENTS="${PROJECT_DIR}/WorldTree.entitlements"

echo "Re-signing with identity ${SIGN_HASH}..."
codesign --force --deep --sign "$SIGN_HASH" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp=none \
    "$APP_DST" 2>&1 || echo "WARNING: Re-sign failed, launchd may reject the binary"

# Verify the signature is valid before proceeding
codesign --verify --verbose "$APP_DST" 2>&1 || echo "WARNING: Signature verification failed"

# Clear the dirty marker — build is complete
rm -f "$DIRTY_FILE"

# Bounce launchd agent to clear cached CDHash.
# On macOS 26+, launchd caches the CDHash of launched binaries. After re-signing,
# the old cached hash no longer matches. We must bootout + bootstrap to force
# launchd to re-read the new CDHash.
UID_DOMAIN="gui/$(id -u)"
PLIST_LABEL="com.forgeandcode.world-tree"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

echo "Bouncing launchd agent to clear CDHash cache..."
launchctl bootout "${UID_DOMAIN}/${PLIST_LABEL}" 2>/dev/null || true
sleep 1
launchctl bootstrap "$UID_DOMAIN" "$PLIST_PATH" 2>&1 || echo "WARNING: Failed to bootstrap launchd agent"

echo "Swap complete. launchd restarting ${APP_NAME} with fresh CDHash."
osascript -e 'display notification "World Tree rebuilt and restarting." with title "Auto-Update" sound name "Glass"' &

echo "=== $(date) Rebuild complete ==="
