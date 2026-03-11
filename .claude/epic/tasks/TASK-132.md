# TASK-132: Implementation log array unbounded growth + dispatch error silent

**Priority**: medium
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: logLines capped at 1000, trims to 500 when exceeded
**Category**: resource-exhaustion
**Source**: QA Audit Wave 6

## Description
1. ImplementationViewModel.logLines grows unbounded (trims by 100 at 5000, not capped). Long tasks consume 100MB+.
2. DB write failure for daemonTaskId is logged but doesn't abort dispatch — phase stays .running with lost task ID.

## Fix
1. Cap logLines at 1000, trim to 500 when exceeded
2. Set phase to .failed() on DB write failure

## Acceptance Criteria
- [ ] logLines never exceeds 1000 entries
- [ ] DB write failure surfaces to user
