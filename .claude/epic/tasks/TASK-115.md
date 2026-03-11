# TASK-115: Test coverage — critical data layer

**Priority**: high
**Status**: ready
**Category**: testing
**Source**: QA Audit Wave 5

## Description
Test coverage audit found 14 completely untested source files. The critical data layer has the highest production risk. This ticket covers the 5 critical-priority test suites.

## Current State
- 13 test suites exist (~240 test cases)
- 8 files have good coverage (75-95%)
- 14 files have zero coverage
- Core data layer is ~70% covered but missing DatabaseManager and migration verification

## Critical Test Suites Needed

### 1. DatabaseManagerTests
- setup() initialization (double-init guard, path resolution)
- Database path priority (override → primary → fallback)
- PRAGMA verification (WAL, foreign keys, busy_timeout)
- WAL checkpoint timer lifecycle
- read()/write() error handling when dbPool is nil

### 2. MigrationManagerTests
- All 20+ migrations idempotent (run twice without error)
- Table/index creation per version
- Schema constraints (CHECK, UNIQUE, PRIMARY KEY)
- Deferred foreign key behavior

### 3. ContextBuilderTests
- buildForkContext() assembly (parent branch + fork point)
- Message truncation at 500 chars
- Section ordering (metadata → summary → messages → fork indicator)
- Nil session ID and empty message list handling

### 4. TimelineStore + CompassStoreTests
- JSON array decoding (blockers, decisions)
- Date parsing from multiple formats
- Staleness calculation (10 min threshold)
- Attention score calculation
- Query filtering by project

### 5. HeartbeatStoreTests
- HeartbeatRun model fields and timestamp parsing
- CrewDispatchJob status lifecycle
- Signal category filtering
- Date range queries

## Acceptance Criteria
- [ ] 5 new test suites created with 25-30 test methods total
- [ ] All critical data layer tests pass
- [ ] DatabaseManager path resolution tested with all scenarios
- [ ] Migration idempotence verified for all versions
