# TASK-100: Shared Scratchpad — SQLite table + CRUD + MCP tools

**Status:** open
**Priority:** critical
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 1 (Foundation)
**Dependencies:** None

## What

Build `cortana-core/src/scratchpad/index.ts` — shared agent state via SQLite table in `world-tree.db`. Expose as MCP tools so any Claude session can read/write.

## Acceptance Criteria

- `scratchpad` table created (id, project, topic, agent, session_id, entry_type, content, promoted, promoted_to, created_at, expires_at)
- `scratchpad_fts` FTS5 virtual table on (content, topic)
- Indexes: `idx_scratchpad_project` on (project, created_at DESC), `idx_scratchpad_promoted` on (promoted) WHERE promoted = 0
- CRUD functions: `write()`, `read()`, `readAll()`, `promote()`, `expire()`, `cleanup()`
- Entry types constrained to: finding, decision, blocker, handoff
- Default expiry: 7 days from creation
- Max entry content: 2000 characters (enforced at write)
- MCP tools registered: `scratchpad_write` (project, topic, entryType, content), `scratchpad_read` (project, topic?, since?)
- Write triggers Compose Layer cache invalidation for that project
- WAL mode, same DB connection pattern as existing tables
- Unit tests for CRUD, expiry, FTS search, promotion

## Key Files

- `cortana-core/src/scratchpad/index.ts` — main module
- `cortana-core/src/scratchpad/scratchpad.test.ts` — tests
- Database: `~/.cortana/world-tree.db`

## Notes

- `search(query)` uses FTS5 with LIKE fallback (existing pattern)
- Wire into Compose Layer's scratchpad section after both modules exist
