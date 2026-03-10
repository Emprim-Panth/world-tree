# TASK-071: Settings — Pencil MCP URL configuration and feature toggle

**Status:** Pending
**Priority:** medium
**Assignee:** Data
**Phase:** 1 — MCP Client
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Add a "Pencil" section to `SettingsView.swift`. Controls:

- **Toggle:** "Enable Pencil integration" (UserDefaults `pencil.feature.enabled`)
- **TextField:** "MCP Server URL" (UserDefaults `pencil.mcp.url`, placeholder `http://localhost:4100`)
- **Status row:** "Connection status" — reads `PencilConnectionStore.isConnected`, shows green/red dot + "Connected" / "Offline" + `lastError` if set
- **Button:** "Test Connection" — calls `PencilConnectionStore.refreshNow()`

Toggle off: clears `PencilDesignSection` from Command Center without app restart. URL field change: triggers reconnect. "Test Connection": shows spinner during async call.

---

## Acceptance Criteria

- [ ] Pencil section visible in Settings
- [ ] Toggle off removes Design section from Command Center immediately
- [ ] URL field accepts any valid HTTP URL; invalid URLs show inline validation message
- [ ] Port validation: numeric component in range 1024–65535
- [ ] "Test Connection" shows spinner, updates status row on completion
- [ ] No regression on existing Settings sections

---

## Context

**Why this matters:** Pencil's MCP port isn't fixed — users need to configure the URL. The feature flag keeps it invisible to users who don't use Pencil.

**Related:** TASK-067 (URL read from UserDefaults), TASK-069 (store to test), TASK-070 (toggle hides/shows Design section)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-067*
