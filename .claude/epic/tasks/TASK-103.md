# TASK-103: Session Pool — dispatch integration

**Status:** open
**Priority:** high
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 2 (Session Infrastructure)
**Dependencies:** TASK-102

## What

Replace WorldTree's cold-start dispatch (TerminalLauncher) with harness pool dispatch. Tasks go through the daemon instead of opening new terminals.

## Acceptance Criteria

- WorldTree dispatch UI sends task to harness via HTTP (`POST /pool/dispatch`)
- Harness assigns warm session, injects task via tmux send-keys
- `GET /pool/status` returns current pool state for WorldTree UI consumption
- TerminalLauncher remains as fallback when harness is offline
- Dispatch latency: <1s for warm session, <15s cold fallback
- Task assignment recorded in session_pool table (project, last_activity)

## Key Files

- `cortana-core/src/harness/session-pool.ts` — dispatch endpoint
- WorldTree `Sources/Core/` — dispatch client update

## Notes

- This task wires the pool into the actual workflow. TASK-102 builds the pool; this task uses it.
- WorldTree should detect harness availability and show pool status in Command Center.
