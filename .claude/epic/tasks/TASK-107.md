# TASK-107: Session ID enumeration via API

**Priority**: medium
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Uniform 404 for all /api/messages failure modes
**Category**: security
**Source**: QA Audit Wave 2

## Description
`/api/messages/{sessionId}` leaks session existence information. Different response codes for "exists but unauthorized" vs "doesn't exist" enable enumeration attacks.

## Acceptance Criteria
- [ ] Return identical responses for missing and unauthorized sessions
- [ ] Use constant-time comparison for session lookups
- [ ] Add tests verifying no information leakage
