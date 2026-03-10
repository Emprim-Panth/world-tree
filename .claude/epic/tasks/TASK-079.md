# TASK-079: Three new MCP tools in PluginServer — ticket+frame query tools

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 3 — World Tree MCP Tools
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Extend `PluginServer.swift` with three new tools. Add to `toolsListResponse()` and wire into `callTool()`.

**Tool 1: `world_tree_list_pen_assets`**
- Input: `{ project: string (optional) }`
- Returns: `[{ id, project, file_name, frame_count, node_count, last_parsed }]`
- Purpose: "What .pen design files are attached to this project?"

**Tool 2: `world_tree_get_frame_ticket`**
- Input: `{ frame_id: string, pen_asset_id: string }`
- Returns: `{ ticket_id, ticket_title, ticket_status, ticket_priority, file_path }` or `null`
- Purpose: "What TASK does this design frame implement?"

**Tool 3: `world_tree_list_ticket_frames`**
- Input: `{ ticket_id: string, project: string }`
- Returns: `[{ frame_id, frame_name, file_name, pen_asset_id }]`
- Purpose: "What design frames implement this ticket?"

All three follow the established `textResult(id:text:)` / `mcpError(id:message:)` helper pattern. All queries go through `DatabaseManager.shared.asyncRead` — never block main thread.

---

## Acceptance Criteria

- [ ] `tools/list` response includes all 3 new tools with correct JSON Schema
- [ ] `world_tree_list_pen_assets` returns `[]` (not error) when no assets exist
- [ ] `world_tree_get_frame_ticket` returns `null` content (not error) when no link exists
- [ ] `world_tree_list_ticket_frames` returns correct frames for a known ticket
- [ ] Existing 4 tools unchanged — no regression
- [ ] All DB queries through `asyncRead`

---

## Context

**Why this matters:** This is the payoff. A Claude Code session mid-implementation can call `world_tree_get_frame_ticket` and get the full ticket context for a Pencil frame — description, acceptance criteria, priority — without leaving the terminal. World Tree becomes a live reference that every Claude Code session can query.

**Pattern to follow:** Existing tools in `PluginServer.swift`.

**Related:** TASK-075 (data source), TASK-080 (version bump), TASK-081 (Worf tests)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-075*
