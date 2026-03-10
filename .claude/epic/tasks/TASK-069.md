# TASK-069: PencilConnectionStore — observable connection state for UI

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 1 — MCP Client
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

`@MainActor final class PencilConnectionStore: ObservableObject` under `Sources/Core/Pencil/PencilConnectionStore.swift`.

Published state:
- `@Published var isConnected: Bool`
- `@Published var lastEditorState: PencilEditorState?`
- `@Published var lastLayout: PencilLayout?`
- `@Published var lastVariables: [PencilVariable]`
- `@Published var lastError: String?`

Methods:
- `func startPolling()` — polls `ping()` every 5 seconds, updates `isConnected`; when connected, calls `getEditorState()` and `snapshotLayout()` on first successful ping and then every 30 seconds
- `func stopPolling()`
- `func refreshNow() async` — one-shot full refresh (called by UI refresh button)

Uses `Task` + sleep loop pattern matching `HeartbeatStore.swift`. Polling stops cleanly when `stopPolling()` is called — no retain cycles, no continuation leaks. Does not poll when window is backgrounded.

---

## Acceptance Criteria

- [ ] `isConnected` transitions `false → true` within 6 seconds of Pencil server starting
- [ ] `isConnected` transitions `true → false` within 11 seconds of Pencil server stopping
- [ ] Polling stops cleanly when `stopPolling()` is called
- [ ] `lastEditorState` is `nil` when disconnected
- [ ] `shared` singleton initializer accepts a mock client for testing: `PencilConnectionStore(client: MockPencilClient)`

---

## Context

**Why this matters:** This is the observable bridge between the raw client and SwiftUI views. Data and all UI code observe this store — they never touch `PencilMCPClient` directly.

**Pattern to follow:** `HeartbeatStore.swift` for the polling loop pattern.

**Related:** TASK-067 (client), TASK-068 (models), TASK-070 (Design tab consumes this), TASK-071 (Settings reads `isConnected`)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-067, TASK-068*
