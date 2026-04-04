# TASK-106: WorldTree UI — Session Pool View

**Status:** open
**Priority:** high
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 3 (Communication)
**Dependencies:** TASK-102, TASK-104

## What

New WorldTree panel showing all session pool rooms — their status, project assignment, and ability to attach/detach.

## Acceptance Criteria

- New nav item "Sessions" in WorldTree sidebar (or replaces existing session UI)
- Shows all pooled sessions: name, status (warming/ready/busy/cooling/dead), assigned project, last activity
- Color-coded status indicators using `Palette.*` tokens
- Attach action: opens session in Ghostty/tmux (reuse existing TerminalLauncher pattern)
- Detach action: returns session to pool
- Auto-refreshes from harness `GET /pool/status` on timer + bridge events
- Shows pool health summary: warm count, busy count, total
- Empty state when harness is offline: "Harness not running — sessions use cold start"

## Key Files

- WorldTree `Sources/Features/Sessions/` — new or rebuilt views
- `SessionPoolStore.swift` — state management
- `SessionPoolView.swift` — main view

## Notes

- Sessions are rooms you walk in and out of. The UI should reflect this metaphor.
- Use existing design patterns from Command Center cards.
