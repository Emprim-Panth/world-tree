# TASK-102: Session Pool — warm session management

**Status:** open
**Priority:** high
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 2 (Session Infrastructure)
**Dependencies:** TASK-098, TASK-101

## What

Build `cortana-core/src/harness/session-pool.ts` — maintains warm Claude Code sessions in tmux for instant task dispatch.

## Acceptance Criteria

- Pool maintains `warmSize` (default 2) ready sessions at all times
- `session_pool` table in world-tree.db (id, tmux_session, status, project, composed_hash, last_activity, pid, created_at)
- Session states: warming, ready, busy, cooling, dead
- `dispatch(task)` assigns a warm session in <1s — context already loaded via Compose Layer
- `release(sessionId)` re-composes context and returns session to pool (not killed)
- Dead session detection via PID check every 30s, auto-replaced
- Session timeout: 2h max busy time, force-return to pool
- `healthCheck()` returns pool status (warm count, busy count, dead count)
- If no warm session available, falls back to cold-start (current behavior)
- Index: `idx_session_pool_status` on (status)

## Key Files

- `cortana-core/src/harness/session-pool.ts` — pool manager
- Database: `~/.cortana/world-tree.db`

## Notes

- M4 Max has 128GB RAM — pool size 2 is conservative, can tune up in TASK-112
- Sessions are tmux sessions with `claude --dangerously-skip-permissions` pre-loaded
- Composed context hash stored per session for cache validation
