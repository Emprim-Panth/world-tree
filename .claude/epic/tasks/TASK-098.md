# TASK-098: HIGH — Database trigger + query performance issues

**Status:** Done
**Priority:** high
**Assignee:** —
**Phase:** Performance
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Multiple database performance issues that compound under load:

### 1. Invalid MAX() in denormalization trigger (MigrationManager.swift:548)
```sql
last_message_at = MAX(COALESCE(last_message_at, ''), NEW.timestamp),
```
`MAX()` comparing strings and timestamps. Sidebar stats diverge from truth over time.

**Fix:** Use `CASE WHEN COALESCE(last_message_at, '') < NEW.timestamp THEN NEW.timestamp ELSE last_message_at END`

### 2. N+1 subqueries on message insert triggers (MigrationManager.swift:550, 555)
Every message insert runs 2 separate SELECT subqueries to find tree_id. Bulk imports (copyMessages) trigger O(n) subqueries.

### 3. getTrees() recalculates message counts (TreeStore.swift:44-119)
Sidebar loading recalculates per-tree, then getTree() recalculates per-branch. Redundant work.

### 4. Unbounded graph traversal (GraphStore.swift:119-179)
`getNeighbors()` frontier grows exponentially. No LIMIT on edge fetch, no frontier cap. Memory exhaustion possible on dense graphs.

### 5. Backward pagination (MessageStore.swift:27-41)
Loads most recent N messages (DESC) then reverses (ASC). Loading 100K messages is O(n) per page.

## Acceptance Criteria

- [ ] Fix MAX() SQL in trigger to use CASE WHEN
- [ ] Consolidate trigger subqueries or cache tree_id
- [ ] getTrees() populates message counts, eliminating redundant queries
- [ ] Graph traversal bounded: LIMIT 1000 per level, frontier cap 100
- [ ] Implement keyset pagination for messages

## Files

- `Sources/Core/Database/MigrationManager.swift` (lines 539-570, 550, 555)
- `Sources/Core/Database/TreeStore.swift` (lines 44-119)
- `Sources/Core/Database/GraphStore.swift` (lines 119-179)
- `Sources/Core/Database/MessageStore.swift` (lines 27-41)

## Completion

Fixed in cycle 3 — Migration 17 denormalizes message_count, last_message_at, last_assistant_snippet into canvas_trees with auto-sync triggers. Commit 4665e6f.
