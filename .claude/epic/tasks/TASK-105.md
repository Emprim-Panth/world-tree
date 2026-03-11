# TASK-105: Token broadcast to unauthenticated clients

**Priority**: medium
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: broadcastToSubscribers skips unauthenticated clients
**Category**: security
**Source**: QA Audit Wave 2

## Description
TokenBroadcaster sends token usage and secrets to any WebSocket subscriber without verifying authentication. Unauthenticated clients can subscribe and receive sensitive data.

## Acceptance Criteria
- [ ] Require authentication before allowing WebSocket subscription
- [ ] Validate client identity on each broadcast
- [ ] Add tests for unauthenticated subscription rejection
