# WorldTree Working State

**Last updated:** 2026-02-25

## Status
Core bugs fixed this session. Sidebar collapsible structure in place.

## Pending
- Remove path row from `ProjectGroupHeader` in `SidebarView.swift` (lines 848–870)
  - User approved the plan. Not yet implemented.
  - Move path editing to context menu (keep `commitPath()` + `onPathChanged`).

## Notes
- CortanaCanvas deleted — WorldTree/ is sole source of truth
- Build via Xcode Run button only (Spotlight/Dock = stale binary)
