# TASK-115: v44 Migration — knowledge_write_log audit table

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 1 — DB Foundation
**Agent:** Scotty
**Depends on:** TASK-113
**Blocks:** TASK-119, TASK-125

## What

Create the audit log table that records every knowledge write attempt — both successful and blocked. This is the enforcement paper trail. WorldTree will surface blocked attempts as alerts.

## Acceptance Criteria

- [ ] `knowledge_write_log` table created with: id, session_id, crew_member, attempted_namespace, assigned_namespace, blocked (0/1), reason, created_at
- [ ] Index on (crew_member, blocked)
- [ ] Index on created_at DESC
- [ ] Migration registered as `"v44_knowledge_write_log"`
- [ ] All existing tests pass

## Schema

```sql
CREATE TABLE knowledge_write_log (
    id                  TEXT PRIMARY KEY,
    session_id          TEXT,
    crew_member         TEXT,
    attempted_namespace TEXT NOT NULL,
    assigned_namespace  TEXT,
    blocked             INTEGER NOT NULL DEFAULT 0,
    reason              TEXT,
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_kwl_crew_blocked ON knowledge_write_log(crew_member, blocked);
CREATE INDEX idx_kwl_created ON knowledge_write_log(created_at DESC);
```

## File

`Sources/Core/Database/MigrationManager.swift`
