# TASK-080: PluginServer manifest update — version bump + app startup wiring

**Status:** Pending
**Priority:** medium
**Assignee:** Geordi
**Phase:** 3 — World Tree MCP Tools
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Two changes:

1. **Version bump:** Bump `PluginServer.pluginVersion` from `"1.0.0"` to `"1.1.0"`. Update `writeManifestFile()` to include `"tool_count": 7` in the manifest JSON at `~/.cortana/state/plugins/world-tree.json`. Version must be a single constant — not hardcoded in two places.

2. **App startup wiring:** Update `WorldTreeApp` startup sequence to call `PencilConnectionStore.shared.startPolling()` when `pencil.feature.enabled` is `true`. This ensures the Design section is live from app launch without requiring the user to navigate to Command Center first.

---

## Acceptance Criteria

- [ ] Manifest at `~/.cortana/state/plugins/world-tree.json` contains `"version":"1.1.0"` and `"tool_count":7` after server start
- [ ] Version is defined as a single constant, referenced in both server and manifest
- [ ] Polling starts on app launch when feature is enabled (verified in Settings immediately after open with Pencil running)
- [ ] No regression on daemon handshake

---

## Context

**Why this matters:** The cortana-daemon uses the manifest to discover World Tree's capabilities. Bumping the version signals 3 new tools are available. App startup wiring means Evan doesn't have to manually trigger polling.

**Related:** TASK-079 (tools registered here), TASK-081 (manifest version tested)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-079*
