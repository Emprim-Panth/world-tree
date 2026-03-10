# TASK-077: Ticket detail — "Implemented by" design frames section

**Status:** Done
**Priority:** medium
**Assignee:** Data
**Phase:** 2 — .pen File Support
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Extend the ticket detail view (inspect `AllTicketsView.swift` to confirm exact file) to show an "Implemented by" section when `PenAssetStore.links(for: ticket.id, project: ticket.project)` returns at least one result.

Section header: `"DESIGN FRAMES"` — matching the `"RECENT"` section label pattern in `CommandCenterView`.

Each row: `<file_name.pen>` — `<frame_name>` with a `"pencil.circle"` icon. Tapping opens `PencilFrameInspectorView` for that asset, filtered to that frame.

No empty state needed — section is simply absent when no frames are linked.

---

## Acceptance Criteria

- [ ] Section absent when no frame links exist
- [ ] Section appears correctly for a ticket linked via annotation
- [ ] Each row shows pen file name and frame name
- [ ] Tapping a frame row opens inspector at the correct frame
- [ ] No crash when `PenAssetStore` has no data

---

## Context

**Why this matters:** Closes the loop — from a ticket, Evan can see exactly which design frames implement it. From a frame, he can see which ticket it belongs to. Full bidirectional traceability.

**Related:** TASK-075 (data source), TASK-076 (inspector opened from here)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-075, TASK-076*
