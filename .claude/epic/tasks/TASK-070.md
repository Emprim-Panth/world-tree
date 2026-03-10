# TASK-070: Design Tab in Command Center — canvas connection status + frame list

**Status:** Pending
**Priority:** high
**Assignee:** Data
**Phase:** 1 — MCP Client
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Add a collapsible "Design" section to `CommandCenterView.swift` below `projectGrid`. Structure mirrors `ActiveWorkSection`.

**When disconnected:** Empty state — pencil icon + "Pencil not running" + small note "Start Pencil in your IDE to connect."

**When connected:** Show `PencilEditorState.currentFile` (filename only, not full path), frame count, selected node count, and a `PencilFrameListView` — compact list of frames from `lastLayout.frames` showing: frame name, dimensions (width × height), and a ticket badge if the frame's `annotation` maps to a known ticket ID (Phase 1 shows raw annotation string; Phase 2 populates ticket badges).

New file: `Sources/Features/CommandCenter/PencilDesignSection.swift`

Status pill follows the `statusPill()` helper pattern in `CommandCenterView`: icon `"pencil.circle"`, text "Pencil connected" / "Pencil offline", color `.green` / `.gray`.

Feature-flagged: hidden entirely when `UserDefaults bool "pencil.feature.enabled"` is `false` (default `false`).

Tapping a frame row calls `PencilMCPClient.batchGet([frameId])` and shows `PencilFrameInspectorView` — Phase 1 can show raw JSON in a `Text` view; Phase 2 fills in the real inspector.

---

## Acceptance Criteria

- [ ] Section hidden when `pencil.feature.enabled == false`
- [ ] "Pencil offline" empty state renders without layout warnings in Xcode preview
- [ ] Frame list shows correctly when connected (verified against running Pencil)
- [ ] Connection status pill uses correct colors (green/gray)
- [ ] No hardcoded frame data — all driven by `PencilConnectionStore`
- [ ] Tapping a frame row opens `PencilFrameInspectorView` (Phase 1: raw JSON is acceptable)
- [ ] Accessible — VoiceOver labels on all interactive elements

---

## Context

**Why this matters:** This is what Evan actually sees. The Command Center gains a live window into the design canvas — connection status, current file, all frames — without leaving the app.

**Pattern to follow:** `ActiveWorkSection` composition and `CompassProjectCard` visual style.

**Related:** TASK-069 (data source), TASK-071 (Settings toggle), TASK-076 (Phase 2 inspector)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-069*
