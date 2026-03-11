# TASK-130: Stream cache partial writes + file handle leak

**Priority**: medium
**Status**: ready
**Category**: data-integrity
**Source**: QA Audit Wave 6

## Description
StreamCacheManager writes token chunks without fsync (crash loses data). File handles accumulate in `handles` dict if sessions crash before closeStream() — eventual fd exhaustion.

## Fix
1. Call synchronizeFile() periodically (every N chunks or every 5s)
2. Add timeout-based cleanup scanning for stale handles (>5 min)

## Acceptance Criteria
- [ ] Stream data survives process crash
- [ ] Stale file handles cleaned up automatically
