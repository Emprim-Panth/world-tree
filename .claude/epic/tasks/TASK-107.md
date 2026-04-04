# TASK-107: WorldTree UI — Scratchpad View

**Status:** open
**Priority:** medium
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 3 (Communication)
**Dependencies:** TASK-100, TASK-104

## What

New WorldTree panel showing live agent findings from the shared scratchpad. Project-filterable feed of what agents are discovering.

## Acceptance Criteria

- New nav item or section showing scratchpad entries as a live feed
- Entries show: agent, project, topic, entry type (finding/decision/blocker/handoff), content, timestamp
- Filter by project (dropdown or segmented control)
- Filter by entry type
- Visual distinction for promoted vs unpromoted entries
- Real-time updates via bridge events (scratchpad_write triggers UI refresh)
- Fallback: poll scratchpad table every 10s if bridge is down
- Search via FTS5 (search bar at top)

## Key Files

- WorldTree `Sources/Features/` — new Scratchpad feature
- `ScratchpadStore.swift` — state management (may already exist from prior work)
- `ScratchpadView.swift` — main view

## Notes

- This is the "what are agents thinking" window. It should feel like a live activity feed.
- Entries older than 7 days are auto-expired by scratchpad cleanup — view only shows active entries.
