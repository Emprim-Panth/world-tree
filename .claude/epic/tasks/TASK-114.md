# TASK-114: v43 Migration — scratchpad namespace + crew tags

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 1 — DB Foundation
**Agent:** Scotty
**Depends on:** TASK-113
**Blocks:** TASK-121, TASK-122, TASK-123

## What

Extend the existing `scratchpad` table (created in v40) with namespace routing and crew attribution columns so the dream engine can process entries per-crew and per-namespace.

## Acceptance Criteria

- [ ] `namespace TEXT` column added to scratchpad
- [ ] `crew_member TEXT` column added to scratchpad
- [ ] `promoted INTEGER NOT NULL DEFAULT 0` column added
- [ ] `promoted_at TEXT` column added
- [ ] Index on (namespace, promoted)
- [ ] Index on (crew_member, promoted)
- [ ] Migration registered as `"v43_scratchpad_namespace"`
- [ ] Existing scratchpad rows get namespace=NULL, crew_member=NULL (acceptable — they predate enforcement)
- [ ] All existing tests pass

## File

`Sources/Core/Database/MigrationManager.swift` — add after v42 block
