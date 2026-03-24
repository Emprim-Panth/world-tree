---
id: TASK-27
title: Post-build screenshot hook in cortana-core PostToolUse
status: done
priority: high
epic: EPIC-WT-AGENT-WORKSPACE
phase: 2
---

In cortana-core PostToolUse handler: detect Bash tool calls where output contains "BUILD SUCCEEDED". Boot the default simulator if not running (xcrun simctl boot), launch the app bundle, wait 3 seconds, capture screenshot via peekaboo. Store at `~/.cortana/screenshots/{session_id}-{timestamp}.png`. 10s total timeout, skip silently on failure.
