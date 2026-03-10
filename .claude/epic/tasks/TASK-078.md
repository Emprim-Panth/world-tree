# TASK-078: Worf — Phase 2 verification: asset import + frame linking tests

**Status:** Done
**Priority:** high
**Assignee:** Worf
**Phase:** 2 — .pen File Support
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Test suite under `Tests/PenAssetStoreTests/`.

Tests:

1. **`testImportCountsFramesCorrectly()`** — imports `Tests/Fixtures/sample.pen`, asserts `frame_count == 3`, `node_count >= 3`
2. **`testFrameLinkResolvesTicketAnnotation()`** — imports fixture with `annotation: "TASK-001"`, inserts matching row into `canvas_tickets`, calls `syncFrameLinks`, asserts `pen_frame_links.ticket_id == "TASK-001"`
3. **`testFrameLinkNullTicketWhenNoMatch()`** — annotation `"TASK-999"` with no matching ticket, asserts link row exists but `ticket_id IS NULL`
4. **`testDeleteCascadesToFrameLinks()`** — import, then delete asset, assert `pen_frame_links` is empty
5. **`testMigrationV22IsIdempotent()`** — runs migration twice on same in-memory database, asserts no error

Uses in-memory `DatabasePool` following the `setDatabasePoolForTesting()` pattern in `DatabaseManager`. Reuses `Tests/Fixtures/sample.pen` committed in TASK-072.

---

## Acceptance Criteria

- [ ] All 5 tests pass without network access
- [ ] Tests use in-memory DB — no file I/O except fixture reads
- [ ] `xcodebuild test` passes cleanly
- [ ] Tests follow the same `XCTestCase` pattern as `TreeStoreTests`

---

## Context

**Why this matters:** Worf's gate for Phase 2. The import/link pipeline is the core of Phase 2 — if this is wrong, Phase 3 MCP tools return bad data.

**Related:** TASK-075 (implementation being tested), TASK-072 (fixture committed here)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-075*
