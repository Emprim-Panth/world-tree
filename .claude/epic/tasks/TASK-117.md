# TASK-117: Stress test plan

**Priority**: medium
**Status**: ready
**Category**: testing
**Source**: QA Audit Wave 3

## Description
Document specific stress test scenarios for QA validation before shipping.

## Scenarios

### Database Stress
1. Create 1000+ branches in a single tree — verify sidebar performance
2. Load conversation with 10,000+ messages — verify scroll performance
3. Concurrent reads/writes from World Tree + cortana-core simultaneously
4. WAL checkpoint under heavy write load
5. Migration on a database with 100K+ messages

### Network Stress
6. Gateway disconnection during active dispatch — verify recovery
7. WebSocket reconnection under rapid connect/disconnect cycles
8. 50+ concurrent WebSocket subscribers — verify broadcast performance
9. Large message payloads (>100KB tool output) — verify streaming

### UI Stress
10. Rapid branch switching (click 20 branches in 2 seconds)
11. Type while streaming response — verify no dropped keystrokes
12. Open 10+ terminal tabs simultaneously
13. Search while database is under write load
14. Fork from a branch while stream is active

### Memory Stress
15. Long session (4+ hours) — monitor for memory growth
16. Open/close 100 branches — verify cleanup
17. 1000 search operations — verify no accumulation

## Acceptance Criteria
- [ ] All scenarios documented with expected behavior
- [ ] Pass/fail criteria defined for each scenario
- [ ] Performance baselines established (response time thresholds)
