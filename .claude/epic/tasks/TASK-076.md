# TASK-076: .pen File Inspector UI — read-only frame tree + ticket badges

**Status:** Done
**Priority:** high
**Assignee:** Data
**Phase:** 2 — .pen File Support
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

`PencilFrameInspectorView` under `Sources/Features/CommandCenter/PencilFrameInspectorView.swift`. Shown as a sheet/popover when a frame row in `PencilDesignSection` is tapped.

Layout:
- **Header:** file name + frame count + "Read only" badge
- **Frame tree:** `List` with recursive `PencilNodeRow` — shows node type icon, name/id, x/y, width/height, fill color swatch
- **Frame row footer:** if `PenFrameLink.ticket_id` is non-nil, show a ticket badge `[TASK-067]` that taps to navigate to the ticket in `AllTicketsView`
- **"Import to Project" button:** triggers `PenAssetStore.importPenFile()` for the current live canvas file (path from `PencilEditorState.currentFile`). Disabled when `currentFile` is nil.

Node type icons (SF Symbols):
- frame → `"rectangle.dashed"`
- text → `"textformat"`
- image → `"photo"`
- component → `"puzzlepiece"`
- group → `"rectangle.3.group"`
- unknown → `"square"`

Read-only — no editing of canvas node properties.

---

## Acceptance Criteria

- [ ] Inspector renders correctly with `sample.pen` fixture (preview-testable without live Pencil)
- [ ] Ticket badge appears when `pen_frame_links.ticket_id` is set
- [ ] Tapping ticket badge dismisses inspector and focuses ticket in `AllTicketsView`
- [ ] "Import to Project" is disabled when `PencilEditorState.currentFile` is nil
- [ ] No SwiftUI layout warnings in console during normal use
- [ ] Accessible — tree is VoiceOver navigable

---

## Context

**Why this matters:** This is the primary way Evan inspects a Pencil design from inside World Tree without switching to VS Code. Connects the visual design to the project's tickets.

**Related:** TASK-075 (data source), TASK-070 (entry point), TASK-077 (ticket detail showing linked frames)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-075, TASK-070*
