# TASK-9: Archive deprecated bug tickets (TASK-1 through TASK-8)

**Status:** completed
**Priority:** medium
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 0 — Housekeeping

## Context

TASK-1 through TASK-8 are all bugs in the conversation UI (polling fallback, message ordering, GRDB race conditions, content dedup). All of these systems are being deleted in Phase 1. These tickets are dead on arrival.

## Acceptance Criteria

- [ ] TASK-1 through TASK-8 are closed with status `cancelled`
- [ ] Each closed ticket has a one-line note: "Cancelled — system deleted in EPIC-WT-SIMPLIFY"
- [ ] No action taken to fix any of these bugs (they don't need fixing — the code goes away)

## Notes

Do not fix these bugs. Do not investigate root causes. The only correct resolution is deletion of the systems they belong to.
