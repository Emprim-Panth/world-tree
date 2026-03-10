#!/bin/bash
# Build World Tree and launch from /Applications.
# Usage: ./run.sh [--clean]
#
# The post-build script in project.yml copies to /Applications automatically.
# Always launch from /Applications — never from DerivedData or build/.

set -euo pipefail

cd "$(dirname "$0")"

if [[ "${1:-}" == "--clean" ]]; then
    echo "Clean building..."
    xcodebuild -scheme WorldTree -configuration Debug clean build 2>&1 | tail -5
else
    # Touch a source file to force recompilation when xcodebuild skips changes
    touch Sources/App/WorldTreeApp.swift
    echo "Building..."
    xcodebuild -scheme WorldTree -configuration Debug build 2>&1 | tail -5
fi

if [[ $? -eq 0 ]]; then
    echo "Launching /Applications/World Tree.app..."
    open "/Applications/World Tree.app"
else
    echo "Build failed."
    exit 1
fi
