# TASK-113: v42 Migration — knowledge, namespaces, crew_registry tables

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 1 — DB Foundation
**Agent:** Scotty (Build/DevOps) or Geordi (Architect)
**Blocks:** TASK-114, TASK-115, TASK-116, TASK-117, all Phase 2+ tasks

## What

Add v42 migration to `MigrationManager.swift` creating three new tables:
- `knowledge` — canonical store for all corrections, patterns, decisions, anti-patterns
- `namespaces` — immutable list of valid knowledge routing destinations
- `crew_registry` — hardwired crew member definitions with tier and namespace access

## Acceptance Criteria

- [ ] `knowledge` table created with all columns: id, namespace, crew_member, type, title, body, why, how_to_apply, confidence, source_session, created_at, reviewed_at, promoted_from_scratchpad
- [ ] Indexes on namespace, type, crew_member
- [ ] `namespaces` table created — insert-only by design, agents cannot add rows
- [ ] `crew_registry` table created with: name, tier, role_title, namespaces_read (JSON), namespaces_write (JSON), can_spawn_tiers (JSON), profile_path, active
- [ ] Migration registered as `"v42_knowledge_schema"`
- [ ] `migrationLog.info("v42: knowledge + namespaces + crew_registry tables ready")` on success
- [ ] All existing tests still pass
- [ ] New MigrationManagerTests coverage for v42 tables

## Schema Reference

```sql
CREATE TABLE knowledge (
    id          TEXT PRIMARY KEY,
    namespace   TEXT NOT NULL,
    crew_member TEXT,
    type        TEXT NOT NULL CHECK(type IN ('CORRECTION','DECISION','PATTERN','ANTI_PATTERN','MISTAKE','PREFERENCE','OBSERVATION')),
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    why         TEXT,
    how_to_apply TEXT,
    confidence  TEXT NOT NULL DEFAULT 'M' CHECK(confidence IN ('H','M','L')),
    source_session TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    reviewed_at TEXT,
    promoted_from_scratchpad INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_knowledge_namespace ON knowledge(namespace);
CREATE INDEX idx_knowledge_type ON knowledge(type);
CREATE INDEX idx_knowledge_crew ON knowledge(crew_member);

CREATE TABLE namespaces (
    id          TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    description TEXT NOT NULL
);

CREATE TABLE crew_registry (
    name             TEXT PRIMARY KEY,
    tier             INTEGER NOT NULL CHECK(tier IN (1,2,3,4)),
    role_title       TEXT NOT NULL,
    namespaces_read  TEXT NOT NULL DEFAULT '[]',
    namespaces_write TEXT NOT NULL DEFAULT '[]',
    can_spawn_tiers  TEXT NOT NULL DEFAULT '[]',
    profile_path     TEXT NOT NULL,
    active           INTEGER NOT NULL DEFAULT 1
);
```

## File

`Sources/Core/Database/MigrationManager.swift` — add after v41 block, before `try migrator.migrate(dbPool)`
