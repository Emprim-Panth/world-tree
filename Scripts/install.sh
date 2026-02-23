#!/usr/bin/env bash
# Builds World Tree and installs to /Applications — run this instead of building from Xcode
# when you want the Dock/Spotlight to pick up the latest code.
#
# Usage: ./Scripts/install.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="World Tree"
INSTALL_PATH="/Applications/${APP_NAME}.app"

echo "▸ Building..."
xcodebuild \
  -project "$PROJECT_DIR/WorldTree.xcodeproj" \
  -scheme WorldTree \
  -configuration Debug \
  build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5

# Find the freshest build
BUILT_APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "${APP_NAME}.app" \
  -not -path "*/Index.noindex/*" \
  -type d 2>/dev/null \
  | xargs stat -f "%m %N" 2>/dev/null \
  | sort -rn \
  | head -1 \
  | awk '{print substr($0, index($0,$2))}')

if [ -z "$BUILT_APP" ]; then
  echo "✗ Could not find built app. Build may have failed."
  exit 1
fi

BUILD_NUM=$(defaults read "${BUILT_APP}/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
echo "▸ Installing build ${BUILD_NUM} → ${INSTALL_PATH}"

# Kill running instance if present
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5

# Install
rm -rf "${INSTALL_PATH}"
cp -R "${BUILT_APP}" "${INSTALL_PATH}"

echo "▸ Launching..."
open "${INSTALL_PATH}"

echo "✓ World Tree build ${BUILD_NUM} running from /Applications"
