#!/usr/bin/env bash
# Increments CURRENT_PROJECT_VERSION in project.pbxproj.
# Run before a build to stamp the version so Settings → General shows the new number.
# Usage: ./Scripts/bump-build.sh

set -euo pipefail

PBXPROJ="$(dirname "$0")/../WorldTree.xcodeproj/project.pbxproj"

current=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | grep -o '[0-9]*' | head -1)
next=$((current + 1))

sed -i '' "s/CURRENT_PROJECT_VERSION = ${current};/CURRENT_PROJECT_VERSION = ${next};/g" "$PBXPROJ"

echo "Build number: $current → $next"
echo "Rebuild the app — Settings → General will show 'build $next'."
