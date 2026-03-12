# TASK-156: Comprehensive Test Suite

**Priority**: medium
**Status**: Todo
**Category**: testing
**Epic**: Agent Orchestration Dashboard
**Sprint**: 3
**Agent**: worf
**Complexity**: L
**Dependencies**: TASK-142, TASK-155

## Description

Test coverage for all new stores, models, and integration points. Follows existing test patterns in `Tests/`.

## Files to Create

- **Create**: `Tests/AgentOrchestrationTests/AgentSessionTests.swift`
- **Create**: `Tests/AgentOrchestrationTests/SessionHealthTests.swift`
- **Create**: `Tests/AgentOrchestrationTests/AttentionStoreTests.swift`
- **Create**: `Tests/AgentOrchestrationTests/ConflictDetectorTests.swift`
- **Create**: `Tests/AgentOrchestrationTests/EventRuleStoreTests.swift`
- **Create**: `Tests/AgentOrchestrationTests/TokenStoreExtensionTests.swift`
- **Create**: `Tests/AgentOrchestrationTests/UIStateStoreTests.swift`

## Test Categories

### AgentSessionTests
- Insert + fetch round-trip
- Status enum maps all 9 values
- files_changed JSON decode/encode
- CodingKeys snake_case mapping

### SessionHealthTests
- Score = 1.0 for perfectly healthy session (0 errors, normal burn, low context, files touched)
- Score = 0.0 for worst case (5+ consecutive errors, 95% context, 0 files)
- Yellow zone: 3 errors, 75% context
- Static override: consecutive_errors >= 5 → always red
- Static override: context > 95% → always red
- Static override: status == stuck → always red
- Edge case: brand new session (0 tokens, 0 errors) → green

### AttentionStoreTests
- Events sorted by severity then recency
- Acknowledge removes from unacknowledged list
- Critical count updates correctly
- Auto-acknowledge stale completed events

### ConflictDetectorTests
- Two sessions editing same file → conflict detected
- Two sessions reading same file → no conflict (reads don't conflict)
- One session completed, one active → no conflict
- Same session editing file twice → no self-conflict
- Different files with same name in different projects → no conflict

### EventRuleStoreTests
- Rule creation persists
- Rule evaluation matches trigger conditions
- Cooldown prevents re-triggering within 30 minutes
- Global cap: 4th dispatch in same hour rejected
- Disabled rule skipped during evaluation

### TokenStoreExtensionTests
- Burn rate calculation with known data
- Daily totals aggregate correctly
- Empty database returns zero values

### UIStateStoreTests
- Set + get round-trip for string and bool
- Missing key returns nil
- Overwrite replaces value

## Test Infrastructure

Use in-memory GRDB database for all tests (matching existing test patterns in `Tests/HeartbeatStoreTests/`). Create tables in setUp, destroy in tearDown.

## Acceptance Criteria

- [ ] All tests pass on clean checkout
- [ ] No tests depend on external state (DBs, network, filesystem)
- [ ] Coverage for all edge cases listed above
- [ ] Tests run in < 5 seconds total
- [ ] No flaky tests (run 10x without failure)
