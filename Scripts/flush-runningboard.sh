#!/usr/bin/env bash
# Flushes macOS runningboardd to clear cached CDHash after a rebuild.
# Without this, new builds fail with POSIX 163 ("Launchd job spawn failed").
#
# Requires sudoers entry (see below). Run once to install:
#   sudo visudo -f /etc/sudoers.d/runningboardd
#   evanprimeau ALL = (root) NOPASSWD: /usr/bin/killall runningboardd
#
# Usage: ./Scripts/flush-runningboard.sh

set -euo pipefail

if sudo -n killall runningboardd 2>/dev/null; then
    echo "▸ Flushed runningboardd (CDHash cache cleared)"
    sleep 1  # Give it a moment to respawn
else
    echo "⚠ Could not flush runningboardd (sudo not configured)"
    echo "  Run: sudo killall runningboardd"
    echo "  Or install passwordless rule — see this script's header"
fi
