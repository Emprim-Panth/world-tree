# TASK-075: PenAssetStore — CRUD for .pen file assets + frame→ticket resolution

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 2 — .pen File Support
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

`@MainActor final class PenAssetStore: ObservableObject` under `Sources/Core/Pencil/PenAssetStore.swift`. Follows `TicketStore` pattern.

Models:
```swift
struct PenAsset: Codable, FetchableRecord, PersistableRecord { }  // mirrors pen_assets
struct PenFrameLink: Codable, FetchableRecord, PersistableRecord { } // mirrors pen_frame_links
```

Key methods:
- `func importPenFile(at path: String, project: String) throws -> PenAsset` — reads file, decodes `PencilDocument`, counts frames/nodes, writes to `pen_assets`, calls `syncFrameLinks`
- `func syncFrameLinks(assetId: String, document: PencilDocument)` — for each `PencilFrame`, upsert a `pen_frame_links` row. If `frame.annotation` matches `TASK-\d+`, resolve the ticket by looking up `canvas_tickets` for a matching `id`, write `ticket_id` + `ticket_project` onto the link row
- `func assets(for project: String) -> [PenAsset]`
- `func links(for assetId: String) -> [PenFrameLink]`
- `func links(for ticketId: String, project: String) -> [PenFrameLink]`
- `func deletePenAsset(_ id: String)` — cascades to frame links

`raw_json` populated lazily (only when inspector requests the full document tree). If file >5MB, read from `file_path` on demand, don't write to DB.

All database operations through `DatabaseManager.shared.asyncWrite` — never block MainActor.

---

## Acceptance Criteria

- [ ] `importPenFile` correctly counts frames for the 3-frame fixture document
- [ ] `syncFrameLinks` resolves `annotation: "TASK-067"` to ticket row when ticket exists in `canvas_tickets`
- [ ] `syncFrameLinks` writes `ticket_id = nil` when annotation doesn't match any ticket (no crash)
- [ ] Deleting an asset cascades — `pen_frame_links` rows deleted
- [ ] Duplicate import on same `file_path` upserts cleanly (ON CONFLICT REPLACE)
- [ ] All DB operations go through `asyncWrite` (never block MainActor)

---

## Context

**Why this matters:** This is the data layer for all of Phase 2 UI and Phase 3 MCP tools. Both TASK-076 (inspector) and TASK-079 (MCP tools) depend on it.

**Pattern to follow:** `TicketStore.swift` — MainActor ObservableObject, GRDB queries, upsert pattern.

**Related:** TASK-074 (schema), TASK-076 (UI), TASK-077 (ticket detail), TASK-078 (Worf tests), TASK-079 (MCP tools)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-074, TASK-068*
