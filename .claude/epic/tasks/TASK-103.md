# TASK-103: MEDIUM — Provider pipeline issues: daemon fallback, tmux timeout leak, cancellation race

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** tmux SIGINT on timeout, currentTask?.cancel() in send(), process.terminate() in deinit
**Priority:** medium
**Assignee:** —
**Phase:** Stability
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Issues in the LLM provider and tool execution pipeline:

### 1. ClaudeBridge daemon fallback logic (lines 139-160)
Redundant break statements create confusing control flow. Works but fragile for future modifications.

### 2. AnthropicAPIProvider cancellation state race (lines 69, 297-306)
Cancel + immediate resend can leave old currentTask running if MainActor cleanup hasn't fired yet.

**Fix:** Explicitly cancel and nil currentTask at start of send().

### 3. bashViaTmux timeout resource leak (ToolExecutor.swift:431-436)
After timeout expires, script continues running in tmux. Temp files deleted by defer while script still writes to them.

**Fix:** Send Ctrl-C to tmux session on timeout.

### 4. DispatchRouter silent failure (DispatchRouter.swift:45-53)
If AgentSDKProvider not registered, dispatches silently fail. No startup validation.

### 5. DaemonSocket 10-second timeout blocks GCD queue (DaemonSocket.swift:44-45)
If daemon hangs, recv() blocks for 10s. Multiple daemon calls stack up. No progress indicator.

**Fix:** Reduce to 3-5s, show timeout error, queue calls with cancellation.

### 6. Daemon fallback loses context (ClaudeBridge.swift:128-186)
When daemon fails, fallback to sendDirect() rebuilds context from scratch, losing attachments, recentContext, parentSessionId.

## Acceptance Criteria

- [ ] ClaudeBridge fallback logic simplified with shouldFallback flag
- [ ] AnthropicAPIProvider cancels old task explicitly at send() start
- [ ] bashViaTmux terminates script on timeout (send Ctrl-C)
- [ ] DispatchRouter validates provider registration at startup
- [ ] DaemonSocket timeout reduced, queue with cancellation
- [ ] Daemon fallback preserves full ProviderSendContext

## Files

- `Sources/Core/Claude/ClaudeBridge.swift` (lines 128-186)
- `Sources/Core/Providers/AnthropicAPIProvider.swift` (lines 69, 297-306)
- `Sources/Core/Claude/ToolExecutor.swift` (lines 431-436)
- `Sources/Core/Providers/DispatchRouter.swift` (lines 45-53)
- `Sources/Core/Daemon/DaemonSocket.swift` (lines 44-45)
