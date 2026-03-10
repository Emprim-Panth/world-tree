# TASK-086: Visual diff — Pencil frame vs running app side-by-side

**Status:** Done
**Priority:** medium
**Assignee:** Data
**Phase:** 4 — Visual Verification
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Add a "Compare" button to expanded frame rows in `PencilDesignSection`. Tapping it opens a side-by-side comparison panel: the Pencil frame on the left, a screenshot of the running app on the right.

**Implementation:**

1. **Pencil screenshot** — already implemented in TASK-084/085
2. **App screenshot** — use `PeekabooBridgeServer`'s screenshot capability or `CGWindowListCreateImage` to capture the frontmost non-World-Tree window
3. **Comparison panel** — `HSplitView` or `HStack` with both images, `GeometryReader` to make them fill available space

**UI:**

```
┌─────────────────────┬─────────────────────┐
│     Design (Pencil) │     App (Running)    │
│   [frame thumbnail] │  [app screenshot]    │
│   320 × 640         │  390 × 844           │
└─────────────────────┴─────────────────────┘
          [ Close ]
```

Present as a sheet on the `CommandCenterView` or as a new `PencilDiffView` pushed into a NavigationStack.

**App screenshot strategy:**

```swift
// Capture frontmost window (exclude World Tree process)
let windowList = CGWindowListCreateImageFromArray(
    .zero, // whole screen bounds
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! CFArray,
    [.bestResolution]
)
```

Filter out WorldTree's own windows by checking `kCGWindowOwnerName`.

---

## Acceptance Criteria

- [ ] "Compare" button appears on expanded frame rows
- [ ] Tapping it opens a diff view with Pencil frame on left, app on right
- [ ] Both images scale to fill available height while preserving aspect ratio
- [ ] Labels show pixel dimensions of each image
- [ ] Close button returns to Design tab
- [ ] Works when only Pencil is running (app screenshot is blank/placeholder)
- [ ] Works when only the app is running (Pencil screenshot shows error)

---

## Notes

- This feature requires Screen Recording permission (already granted to World Tree via PermissionsService)
- Don't implement pixel-diff overlays for Phase 4 — side-by-side visual comparison is enough. Pixel diff is a future task.
