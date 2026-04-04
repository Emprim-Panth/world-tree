# TASK-112: Dogfood — 2-week validation

**Status:** open
**Priority:** low
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 5 (Validation)
**Dependencies:** TASK-098 through TASK-110

## What

Use the harness for all real work for 2 weeks. Tune pool size, dream quality, bridge reliability. Validate the system under actual workload before declaring done.

## Acceptance Criteria

- All sessions dispatched through harness (not cold-start) for 2 weeks
- Pool size tuned based on actual memory usage and dispatch patterns
- Dream Engine quality reviewed: promoted entries are actually useful, no garbage promotions
- Bridge stays connected for >95% of active time
- Scratchpad entries are being written by sessions naturally (not forced)
- No manual knowledge promotion needed (dream handles it)
- Cold start time measured: target <3s
- Cross-session knowledge verified: session B reads what session A wrote to scratchpad

## Validation Log

Track daily observations here during the 2-week period:

| Date | Observation | Action Taken |
|------|-------------|--------------|

## Notes

- This is the "does it actually work in practice" gate.
- Findings from this task feed back into tuning the other tasks.
- Only after this passes do we proceed with TASK-111 (cleanup).
