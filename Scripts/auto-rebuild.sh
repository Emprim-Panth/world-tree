#!/bin/zsh
# World Tree auto-rebuild
# Triggered by git post-commit hook — builds and relaunches World Tree immediately.
# Runs in background so commits complete instantly.
# Log: ~/.cortana/logs/wt-rebuild.log

PROJECT_DIR="/Users/evanprimeau/Development/WorldTree"
LOG="$HOME/.cortana/logs/wt-rebuild.log"
LOCKFILE="/tmp/wt-rebuild.lock"

DEBOUNCE_FILE="/tmp/wt-rebuild-last"
DEBOUNCE_SECS=300   # minimum 5 minutes between rebuilds

mkdir -p "$(dirname "$LOG")"

# Only rebuild if Swift source, project config, or scripts actually changed.
# Skips rebuilds from doc-only commits, memory updates, etc.
CHANGED=$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null)
if ! echo "$CHANGED" | grep -qE '\.(swift|yml|yaml|entitlements)$|^Scripts/'; then
    echo "=== $(date) Skipping — no source files changed ===" >> "$LOG"
    exit 0
fi

# Debounce — skip if a rebuild ran within the last 5 minutes.
if [ -f "$DEBOUNCE_FILE" ]; then
    LAST=$(cat "$DEBOUNCE_FILE" 2>/dev/null)
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST ))
    if [ "$ELAPSED" -lt "$DEBOUNCE_SECS" ]; then
        echo "=== $(date) Skipping — last rebuild was ${ELAPSED}s ago (debounce ${DEBOUNCE_SECS}s) ===" >> "$LOG"
        exit 0
    fi
fi
date +%s > "$DEBOUNCE_FILE"

# Serialize concurrent builds — multiple rapid commits would otherwise spawn N builds
# that each killall+relaunch World Tree in rapid succession (the crash-loop bug).
# Use noclobber (set -C) for atomic test-and-set: fails if file already exists.
if ! (set -C; > "$LOCKFILE") 2>/dev/null; then
    echo "=== $(date) Skipping — another build already running (lock: $LOCKFILE) ===" >> "$LOG"
    exit 0
fi
# Release lock on exit regardless of how we leave (success, failure, signal)
trap "rm -f '$LOCKFILE'" EXIT

exec >> "$LOG" 2>&1
echo ""
echo "=== $(date) Auto-rebuild triggered by git commit ==="

cd "$PROJECT_DIR" || { echo "ERROR: Cannot cd to $PROJECT_DIR"; exit 1; }

# Regenerate .xcodeproj if xcodegen is available
if command -v xcodegen &>/dev/null; then
    echo "Regenerating .xcodeproj..."
    xcodegen generate --spec project.yml
else
    echo "xcodegen not found — skipping project regen (using existing .xcodeproj)"
fi

# If Xcode has the project open, it holds the build DB exclusively.
# Let Xcode handle the rebuild in that case — user can ⌘R or it auto-builds.
if pgrep -x "Xcode" &>/dev/null; then
    echo "Xcode is running — skipping CLI build (Xcode will pick up changes on next ⌘R)."
    osascript -e 'display notification "Committed. Press ⌘R in Xcode to rebuild, or close Xcode for auto-build." with title "World Tree" sound name "Pop"' &
    exit 0
fi

# Build — the post-build script in project.yml handles:
#   killall "World Tree", ditto to /Applications/, codesign
echo "Building..."
/usr/bin/xcodebuild \
    -project "WorldTree.xcodeproj" \
    -scheme "WorldTree" \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -quiet \
    build

BUILD_EXIT=$?

if [ $BUILD_EXIT -eq 0 ]; then
    echo "Build succeeded — relaunching World Tree."
    # post-build script already killed the old binary and installed to /Applications.
    # Give it a moment to finish signing, then relaunch.
    sleep 1
    open "/Applications/World Tree.app"
    # Notify so we know it worked even when away from the machine
    osascript -e 'display notification "World Tree rebuilt and relaunched." with title "Auto-Update" sound name "Glass"' &
else
    echo "Build FAILED (exit $BUILD_EXIT)"
    osascript -e 'display notification "World Tree auto-rebuild FAILED. Check ~/.cortana/logs/wt-rebuild.log" with title "Build Error" sound name "Basso"' &
fi
