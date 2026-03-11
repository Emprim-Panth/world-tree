# TASK-110: Force-unwrap in GatewayClient fallback URL

**Priority**: low
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Static defaultURL constant eliminates runtime force-unwrap
**Category**: bug
**Source**: QA Audit Wave 2

## Description
GatewayClient force-unwraps the fallback URL construction. If the hardcoded string is malformed (unlikely but possible during refactoring), the app crashes.

## Acceptance Criteria
- [ ] Replace force-unwrap with guard/let and graceful error
- [ ] Add unit test for URL construction edge cases
