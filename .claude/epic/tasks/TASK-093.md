# TASK-093: HIGH — Race conditions in ClaudeCodeProvider session map + WebSocket handler

**Status:** Done
**Priority:** high
**Assignee:** —
**Phase:** Stability
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Multiple concurrency issues in the provider layer:

### 1. ClaudeCodeProvider session map race (lines 34-38, 251-258, 301-302)
`cliSessionMap` and `cliSessionLastUsed` accessed from multiple threads. `mapLock` protects some access but not all:
- `setCliSession` called from parseQueue without lock
- Session map update in terminationHandler — no lock
- `getCliSession` from main thread without lock

### 2. NativeWebSocketConnection @unchecked Sendable (WebSocketHandler.swift:19)
Mutable callback properties (`_onMessage`, `_onClose`, `_onPong`) accessed from Network.framework threads and MainActor tasks. Lock protects access but `@unchecked Sendable` suppresses compiler safety checks.

### 3. TokenBroadcaster concurrent state cleanup (lines 38-111)
When `broadcast()` called while stream active on same branchId:
- Old task cancellation and new task initialization can race
- `accumulatedText[branchId]` read by old task while being overwritten by new
- Partial messages from old stream mixed with new stream

### 4. Resume failure detection race (ClaudeCodeProvider.swift:254-256)
`getCliSession()` and `setCliSession()` called sequentially without holding lock between them. Another thread could modify session map between calls.

## Acceptance Criteria

- [ ] ALL access to `cliSessionMap`/`cliSessionLastUsed` protected by `mapLock`
- [ ] WebSocketHandler converted to actor or @unchecked Sendable removed
- [ ] TokenBroadcaster uses per-branch isolation or captures state at cancel time
- [ ] Resume detection is atomic (single lock acquisition)
- [ ] No data races detected by Thread Sanitizer

## Files

- `Sources/Core/Providers/ClaudeCodeProvider.swift` (lines 34-38, 170-173, 251-258, 301-302)
- `Sources/Core/Server/WebSocketHandler.swift` (line 19)
- `Sources/Core/Server/TokenBroadcaster.swift` (lines 38-111)

## Completion

Fixed in deep inspect cycles — ClaudeCodeProvider uses NSLock for stateLock/mapLock protecting isRunning, currentProcess, and sessionMap.
