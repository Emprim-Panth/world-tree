# TASK-072: Worf — Phase 1 verification: MCP client tests

**Status:** Done
**Priority:** high
**Assignee:** Worf
**Phase:** 1 — MCP Client
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Test suite under `Tests/PencilMCPClientTests/`.

Tests to write:

1. **`testPingReturnsFalseWhenNoServer()`** — creates `PencilMCPClient` pointed at a port with nothing running, asserts `ping()` returns `false` within 3 seconds
2. **`testDecodesPencilDocument()`** — loads `Tests/Fixtures/sample.pen`, decodes into `PencilDocument`, asserts frame count and node IDs
3. **`testJsonRpcEnvelopeShape()`** — intercepts outgoing request body for `getEditorState()` using a `URLProtocol` mock, asserts correct JSON-RPC 2.0 structure: `{"jsonrpc":"2.0","method":"tools/call","params":{"name":"get_editor_state","arguments":{}},"id":1}`
4. **`testConnectionStoreTransitionsOnPing()`** — injects a mock `PencilMCPClient` that alternates ping results, asserts `isConnected` updates within 1 polling cycle

The `sample.pen` fixture must have at least 3 frames and 1 frame with a non-nil `annotation` field (used again in Phase 2 tests).

---

## Acceptance Criteria

- [ ] All 4 tests pass in CI with no network access (fully mocked)
- [ ] Tests follow `XCTestCase` pattern established in `TreeStoreTests`
- [ ] Fixture `Tests/Fixtures/sample.pen` committed with 3+ frames and 1 annotation
- [ ] No flaky async tests — use `async/await` with `XCTestExpectation` only when truly needed
- [ ] `xcodebuild test` passes cleanly

---

## Context

**Why this matters:** Worf's gate. Nothing in Phase 1 ships without these passing. The fixture also serves Phase 2 tests (TASK-078).

**Related:** TASK-067, TASK-068, TASK-069 (all must be complete first)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-067, TASK-068, TASK-069*
