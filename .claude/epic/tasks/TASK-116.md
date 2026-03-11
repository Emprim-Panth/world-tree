# TASK-116: Test coverage — high priority service layer

**Priority**: medium
**Status**: ready
**Category**: testing
**Source**: QA Audit Wave 5

## Description
Service and integration layer tests covering business logic, external communication, and provider orchestration. Second priority after critical data layer (TASK-115).

## Test Suites Needed

### 1. GatewayClientTests (8-10 methods)
- HTTP request construction (headers, auth token injection)
- JSON encoding/decoding round-trip
- Network error handling (timeout, 500, 404)
- Base URL fallback for malformed input

### 2. ConversationStateManagerTests (6-8 methods)
- API message serialization round-trip
- System prompt state management
- Token usage accumulation
- Concurrent state modification safety

### 3. SynthesisServiceTests (5-6 methods)
- Summary request format construction
- Token budget calculation
- Error handling (no context, timeout, malformed response)

### 4. ClaudeServiceTests (10-12 methods)
- Session initialization
- Provider selection logic
- Error recovery / retry logic
- Budget enforcement

### 5. GraphStoreTests (6-8 methods)
- Branch hierarchy queries (children, ancestors, siblings)
- Tree traversal efficiency
- Orphaned branch detection

## Acceptance Criteria
- [ ] 5 new test suites with 35-45 test methods
- [ ] GatewayClient tested with mock URLSession
- [ ] Provider selection logic verified
- [ ] Graph traversal edge cases covered
