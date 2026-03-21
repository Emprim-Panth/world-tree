#!/usr/bin/env bash
# Builds World Tree and installs to /Applications with proper service lifecycle.
# Handles: launchd stop → kill → copy → sign → flush runningboard → launchd start
#
# Usage: ./Scripts/install.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="World Tree"
INSTALL_PATH="/Applications/${APP_NAME}.app"
SIGN_IDENTITY="4B1FEE2344F79AD30E99304B6454317CDEAB3878"
LAUNCHD_LABEL="com.forgeandcode.world-tree"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
UID_NUM=$(id -u)
DERIVED_DATA_PATH="${WT_DERIVED_DATA_PATH:-/tmp/WorldTree-install}"
LAUNCH_LOG="$HOME/.cortana/logs/world-tree-launchd.log"

write_launchd_plist() {
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.cortana/logs"
  cat >"$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_PATH}/Contents/MacOS/${APP_NAME}</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${LAUNCH_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCH_LOG}</string>
</dict>
</plist>
EOF
}

echo "▸ Building..."
BUILD_LOG=$(mktemp -t worldtree-install-build.XXXXXX.log)
if ! WT_STAGED_BUILD=1 xcodebuild \
  -project "$PROJECT_DIR/WorldTree.xcodeproj" \
  -scheme WorldTree \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG"
  echo "✗ Build failed. Full log: $BUILD_LOG"
  exit 1
fi
grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" "$BUILD_LOG" | tail -5 || true

BUILT_PRODUCTS_DIR=$(
  WT_STAGED_BUILD=1 xcodebuild \
    -project "$PROJECT_DIR/WorldTree.xcodeproj" \
    -scheme WorldTree \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '/ BUILT_PRODUCTS_DIR = / { print $2; exit }'
)
BUILT_APP="$BUILT_PRODUCTS_DIR/${APP_NAME}.app"

if [ ! -d "$BUILT_APP" ]; then
  echo "✗ Could not find built app. Build may have failed."
  exit 1
fi

BUILD_NUM=$(defaults read "${BUILT_APP}/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
echo "▸ Installing build ${BUILD_NUM} → ${INSTALL_PATH}"

# Build and sign the app BEFORE touching the running service.
# This ensures we never stop launchd with an unsigned or broken binary.

# Sign the built app first (before any service disruption)
echo "▸ Signing built app..."
# Strip nested .app bundles from source bundle root (prevents codesign "unsealed contents" failure)
find "${BUILT_APP}" -maxdepth 1 -name "*.app" -type d | while read -r nested; do
  echo "  ⚠ Removing stray nested bundle: $(basename "$nested")"
  rm -rf "$nested"
done
if ! codesign --force --sign "${SIGN_IDENTITY}" \
  --entitlements "${PROJECT_DIR}/WorldTree.entitlements" \
  --options runtime \
  --timestamp=none \
  --deep \
  "${BUILT_APP}"; then
  echo "✗ Signing failed — aborting install (service left running)"
  exit 1
fi
codesign -v "${BUILT_APP}" 2>&1 || { echo "✗ Signature verification failed — aborting"; exit 1; }

# Only stop the service once we have a valid signed binary ready to swap in
echo "▸ Stopping launchd service..."
launchctl bootout "gui/${UID_NUM}/${LAUNCHD_LABEL}" 2>/dev/null || true

# Kill running instance
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5

# Install
rm -rf "${INSTALL_PATH}"
cp -R "${BUILT_APP}" "${INSTALL_PATH}"

write_launchd_plist

# Flush runningboardd CDHash cache
"${PROJECT_DIR}/Scripts/flush-runningboard.sh"

# Restart launchd service
echo "▸ Restarting launchd service..."
launchctl bootstrap "gui/${UID_NUM}" "${LAUNCHD_PLIST}"

echo "✓ World Tree build ${BUILD_NUM} running from /Applications"
