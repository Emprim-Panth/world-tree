# TASK-074: DB Migration v22 — pen_assets and pen_frame_links tables

**Status:** Pending
**Priority:** high
**Assignee:** Geordi
**Phase:** 2 — .pen File Support
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Add migration `v22_pencil_assets` to `MigrationManager.swift`:

```sql
CREATE TABLE IF NOT EXISTS pen_assets (
    id TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    file_path TEXT NOT NULL UNIQUE,
    file_name TEXT NOT NULL,
    frame_count INTEGER DEFAULT 0,
    node_count INTEGER DEFAULT 0,
    raw_json TEXT,                     -- populated lazily (on inspector open, if file < 5MB)
    last_parsed TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_pen_assets_project ON pen_assets(project);
CREATE INDEX IF NOT EXISTS idx_pen_assets_path ON pen_assets(file_path);

CREATE TABLE IF NOT EXISTS pen_frame_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pen_asset_id TEXT NOT NULL REFERENCES pen_assets(id),
    frame_id TEXT NOT NULL,
    frame_name TEXT NOT NULL,
    ticket_id TEXT,                    -- nullable — set when annotation matches TASK-*
    ticket_project TEXT,
    annotation TEXT,                   -- raw annotation string from .pen node
    linked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_pen_frame_links_asset ON pen_frame_links(pen_asset_id);
CREATE INDEX IF NOT EXISTS idx_pen_frame_links_ticket ON pen_frame_links(ticket_id, ticket_project);
```

`raw_json` guard: if file is >5MB, store NULL and read from `file_path` on demand.

Follow the exact pattern of every prior migration in `MigrationManager.swift`.

---

## Acceptance Criteria

- [ ] Migration registered as `"v22_pencil_assets"` — correct naming convention
- [ ] Both tables created with correct schema and FK references
- [ ] Indexes created
- [ ] Safe on re-run (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`)
- [ ] Runs cleanly on fresh DB and on existing DB at v21
- [ ] No column name conflicts with existing `canvas_*` tables
- [ ] Existing tests pass (no schema conflicts)

---

## Context

**Why this matters:** The database is the persistence layer for the entire Phase 2 feature. Geordi must design this schema carefully — once it's in, migration history is permanent.

**Related:** TASK-068 (models stable before schema locks), TASK-075 (PenAssetStore uses these tables)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-068 (models must be stable)*
