# TASK-129: Gateway terminal subscription hangs on permanent failure

**Priority**: medium
**Status**: ready
**Category**: error-recovery
**Source**: QA Audit Wave 6

## Description
GatewayClient.subscribeToTerminal() retries on ANY error up to 10 times with exponential backoff (~2+ min). If gateway is truly down, terminal output appears hung then silently stops.

## Fix
Distinguish transient vs permanent errors. Return error event to UI on permanent failures after 2-3 retries.

## Acceptance Criteria
- [ ] UI shows error after gateway is confirmed unreachable
- [ ] Transient errors still retry with backoff
