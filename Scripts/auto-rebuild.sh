#!/bin/zsh
# World Tree auto-rebuild
# Triggered by git post-commit hook — builds and relaunches World Tree immediately.
# Runs in background so commits complete instantly.
# Log: ~/.cortana/logs/wt-rebuild.log

PROJECT_DIR="/Users/evanprimeau/Development/WorldTree"
LOG="$HOME/.cortana/logs/wt-rebuild.log"
mkdir -p "$(dirname "$LOG")"

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

# Build — the post-build script in project.yml handles:
#   killall "World Tree", ditto to /Applications/, codesign
echo "Building..."
/usr/bin/xcodebuild \
    -project "World Tree.xcodeproj" \
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
