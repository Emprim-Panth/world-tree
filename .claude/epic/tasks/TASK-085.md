# TASK-085: Frame preview panel — inline thumbnail in PencilDesignSection

**Status:** Done
**Priority:** high
**Assignee:** Data
**Phase:** 4 — Visual Verification
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Add an inline frame preview to `PencilDesignSection`. When a user taps a frame row, show a live screenshot from Pencil below the row (or in a popover on macOS).

**UI spec:**

```
┌────────────────────────────────────────────┐
│  Design                              [↻]   │
│  dashboard.pen  •  5 frames                │
│                                            │
│  ▶ Login Screen        320 × 640  TASK-067 │
│    ┌──────────────────────────────────┐    │  ← expanded on tap
│    │         [PNG thumbnail]          │    │
│    └──────────────────────────────────┘    │
│  ▶ Dashboard           375 × 812  TASK-070 │
│  ▶ Settings            375 × 812           │
└────────────────────────────────────────────┘
```

**Implementation:**

- `PencilFrameRow` gets a `@State var isExpanded: Bool`
- On expand: call `PencilConnectionStore.shared.getFrameScreenshot(frameId:)` async
- While loading: show `ProgressView` inside the expansion area
- On success: `Image(nsImage: NSImage(data: pngData))` with `.resizable().scaledToFit()`
- On error: show error text, no crash
- Cache last screenshot per `frameId` in `PencilConnectionStore` (`[String: Data]` dict) to avoid redundant calls

**macOS layout:**

Expanded inline within the list (not a popover) — consistent with Command Center's collapsible section pattern.

---

## Acceptance Criteria

- [ ] Tapping a frame row expands to show its screenshot
- [ ] Loading state shown while screenshot fetches
- [ ] Screenshot cached — second tap is instant
- [ ] Tapping again collapses the preview
- [ ] Only one frame expanded at a time (tapping another collapses the current)
- [ ] Error state shows text, doesn't crash
- [ ] Works when Pencil is disconnected (disable tap or show "Pencil not running")

---

## Notes

- Max thumbnail height: 300pt. Use `.frame(maxHeight: 300)` to prevent huge frames from dominating.
- Thumbnail is read from Pencil live — reflects the current canvas state, not the imported `.pen` snapshot.
