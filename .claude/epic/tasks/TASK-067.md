# TASK-067: PencilMCPClient — HTTP MCP client for Pencil's local server

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 1 — MCP Client
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Implement an actor `PencilMCPClient` under `Sources/Core/Pencil/PencilMCPClient.swift`. Follows the `GatewayClient` actor pattern with URLSession. On init, reads the Pencil server URL from `UserDefaults` (key: `pencil.mcp.url`, default `http://localhost:4100`).

Exposes async methods wrapping each of Pencil's 7 MCP tools:
- `batchDesign(ops: [[String: Any]]) async throws -> PencilBatchResult`
- `batchGet(nodeIds: [String]) async throws -> [PencilNode]`
- `getScreenshot() async throws -> Data`
- `snapshotLayout() async throws -> PencilLayout`
- `getEditorState() async throws -> PencilEditorState`
- `getVariables() async throws -> [PencilVariable]`
- `setVariables(_ vars: [PencilVariable]) async throws`

Each method sends `POST /mcp` with a JSON-RPC 2.0 `tools/call` body and deserializes the `result.content[0].text` field as JSON. Errors map to a `PencilMCPError` enum: `serverUnreachable`, `toolCallFailed(String)`, `parseError`.

Must include a `ping() async -> Bool` method (calls `GET /health` or `initialize`) for the connection status indicator.

**NOTE:** `batchDesign` and `setVariables` are `internal` only — World Tree is a read-only consumer. Never expose them to UI.

---

## Acceptance Criteria

- [ ] Actor compiles and does not import any UI frameworks
- [ ] `ping()` returns `false` within 2 seconds when Pencil is not running (2s timeout override on URLSession config)
- [ ] `getEditorState()` correctly deserializes a real Pencil response snapshot (captured in test fixture)
- [ ] All 7 tool methods are implemented with correct JSON-RPC 2.0 envelope
- [ ] No `@MainActor` on the actor itself — all UI bridging happens at the call site
- [ ] `batchDesign` and `setVariables` marked `internal` with comment: `// Intentionally not exposed to UI — read-only consumer policy`

---

## Context

**Why this matters:** This is the connection layer between World Tree and Pencil's running MCP server. Without it, World Tree can't read canvas state. Everything in Phase 1 depends on this.

**Pattern to follow:** `GatewayClient.swift` — actor, URLSession, 15s/60s timeouts, no `@MainActor` on actor itself.

**Related:** TASK-068 (models), TASK-069 (store), TASK-072 (Worf tests)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*No blockers*
