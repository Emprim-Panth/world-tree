# TASK-081: Worf — Phase 3 verification: MCP tool integration tests

**Status:** Pending
**Priority:** high
**Assignee:** Worf
**Phase:** 3 — World Tree MCP Tools
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Extend `Tests/SmokeTests/CriticalPathSmokeTests.swift` or add `Tests/PluginServerPencilTests/` with:

1. **`testToolsListIncludesPencilTools()`** — calls `handleMCP` with `tools/list`, asserts JSON response contains `"world_tree_list_pen_assets"`, `"world_tree_get_frame_ticket"`, `"world_tree_list_ticket_frames"`
2. **`testListPenAssetsEmptyProject()`** — calls `world_tree_list_pen_assets` with `project: "NonExistent"`, asserts `result.content[0].text == "[]"` (not an error)
3. **`testGetFrameTicketMissingFrame()`** — calls `world_tree_get_frame_ticket` with bogus IDs, asserts `null` in content (no MCP error code)
4. **`testManifestVersionBumped()`** — reads manifest JSON written by `writeManifestFile()`, asserts `version == "1.1.0"` and `tool_count == 7`

Uses in-memory database seeded with fixture data. Manifest write mocked to a temp path (no file system side effects).

---

## Acceptance Criteria

- [ ] All 4 tests pass
- [ ] Tests exercise the actual `handleMCP` path (not mocked) to catch JSON serialization bugs
- [ ] No file system side effects from test runs
- [ ] `xcodebuild test` passes cleanly including existing smoke tests

---

## Context

**Why this matters:** Worf's final gate. If these pass, the MCP tools are correctly wired end-to-end and Claude Code sessions can use them reliably.

**Related:** TASK-079 (tools tested), TASK-080 (manifest tested)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-079, TASK-080*
