# TASK-102: MEDIUM — Database migration safety issues

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** Pre-migration backup, WAL checkpoint, FTS5 IF NOT EXISTS, CTE depth guard LIMIT 100
**Priority:** medium
**Assignee:** —
**Phase:** Database
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Several migration safety issues that could cause data integrity problems:

### 1. Incomplete orphan cleanup in v18 (MigrationManager.swift:602-612)
Cleans `canvas_branch_tags` and `canvas_api_state` but NOT:
- `canvas_token_usage`
- `canvas_events`
- `canvas_context_checkpoints`
- `canvas_screenshots`
- `canvas_dispatches`

Orphaned rows in these tables grow database size.

### 2. Non-atomic FTS5 rebuild (Migrations 12, 16)
DROP → CREATE → REBUILD is not atomic. If CREATE fails after DROP, FTS table doesn't exist. Triggers try to INSERT INTO nonexistent table.

### 3. TicketStore.scanAll() not transactional (lines 193-230)
If one upsert fails at position 50/100, first 49 committed, rest lost. Partial state.

### 4. TokenStore.record() uses separate transactions (lines 19-44)
Insert and metrics update in separate writes. Metrics fall behind if second fails.

### 5. Missing cascade for pen_frame_links on tree delete (TreeStore.swift:231-305)

### 6. CTE cycle detection missing in getBranchPath() (TreeStore.swift:578-594)
If parent_branch_id creates a cycle, recursive CTE loops until SQLite depth limit (1000).

## Acceptance Criteria

- [ ] v18 cleanup covers ALL dependent tables
- [ ] FTS5 operations wrapped in transaction with IF NOT EXISTS
- [ ] TicketStore.scanAll() uses single transaction with rollback
- [ ] TokenStore combines record + metrics in single write
- [ ] Tree deletion cascades to pen_frame_links
- [ ] getBranchPath() CTE has max depth guard (100)

## Files

- `Sources/Core/Database/MigrationManager.swift` (lines 278-310, 602-612)
- `Sources/Core/Database/TicketStore.swift` (lines 193-230)
- `Sources/Core/Database/TokenStore.swift` (lines 19-44)
- `Sources/Core/Database/TreeStore.swift` (lines 231-305, 578-594)
