# TASK-111: Delete old daemon, cortex, remove dead code

**Status:** open
**Priority:** low
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 5 (Cleanup)
**Dependencies:** TASK-101, TASK-102, TASK-109

## What

Remove all superseded code once the harness is stable and running.

## Deletion Manifest

| File / Module | Lines | Reason |
|---------------|-------|--------|
| `~/.cortana/daemon/cortana-daemon.py` | 1153 | Replaced by Bun Harness |
| `~/.cortana/daemon/com.cortana.daemon.plist` | 30 | Replaced by new launchd plist |
| `~/.cortana/daemon/cortana-daemon.pid` | 1 | Stale PID file |
| WorldTree `Features/Sessions/*` (old session files) | ~600 | Rebuilt as Session Pool View |
| WorldTree `Features/CommandCenter/DispatchSheet.swift` | ~100 | Replaced by harness dispatch |
| `cortana-core/src/cortex/` | ~1800 | Folded into Harness daemon |
| `cortana-core/bin/cortana-cortex.ts` | ~50 | Replaced by harness |
| `cortana-core/bin/cortana-heartbeat.ts` | ~38K | Consolidated into harness health |

## Acceptance Criteria

- All files in deletion manifest removed
- No remaining imports or references to deleted modules
- Build succeeds after deletion
- Tests pass after deletion
- Commit message lists everything deleted

## Notes

- Do NOT delete until Phase 2-4 systems are confirmed stable (TASK-112 validates this).
- Delete in a single commit — no partial cleanup.
