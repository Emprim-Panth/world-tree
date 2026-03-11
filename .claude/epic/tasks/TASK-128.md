# TASK-128: Silent daemon health check failures

**Priority**: high
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Added wtLog for HTTP health check failures instead of empty catch
**Category**: error-recovery
**Source**: QA Audit Wave 6

## Description
DaemonService health check (lines 81-116) silently ignores HTTP check failures with empty `catch {}`. App thinks daemon is disconnected when it may be reachable, causing unnecessary retries and user delays.

## Fix
Add wtLog for each health check method success/failure to aid debugging.

## Acceptance Criteria
- [ ] Health check failures logged with method name and error
- [ ] Fallback chain reports which check succeeded
