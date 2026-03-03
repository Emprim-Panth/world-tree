# TASK-057: feat: iOS offline support (GRDB local cache)

**Status:** Done
**Priority:** Critical
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Add local SQLite cache to WorldTreeMobile so the app shows cached conversations when disconnected.
Uses GRDB.swift (same as macOS) via SPM.

## Acceptance Criteria

- [ ] GRDB added to iOS SPM dependencies
- [ ] Local DB mirrors trees, branches, messages tables
- [ ] App shows cached content when WebSocket is disconnected
- [ ] Cache syncs (merge, not replace) on reconnect
- [ ] Cache eviction: messages older than 30 days auto-pruned

---

## Implementation Notes

- DB path: `~/Library/Application Support/WorldTreeMobile/local.db`
- Tables: `cached_trees`, `cached_branches`, `cached_messages`
- Sync: on `trees_list` / `branches_list` / `messages_list` events, upsert into cache
- Read order: always serve from cache first; overlay with live data on reconnect
