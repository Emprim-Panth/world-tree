# TASK-112: HeartbeatStore reads non-existent tables on fresh install

**Priority**: low
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: db.tableExists() guards before all cortana-core table queries
**Category**: bug
**Source**: QA Audit Wave 2

## Description
HeartbeatStore queries heartbeat_runs, governance_journal, and other tables that may not exist on a fresh install (created by cortana-core, not World Tree migrations). This produces noisy error logs.

## Acceptance Criteria
- [ ] Check table existence before querying
- [ ] Gracefully return empty results for missing tables
- [ ] Suppress or downgrade log level for expected missing tables
