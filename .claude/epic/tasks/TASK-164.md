# TASK-164: MEDIUM — Stream flush timer not stopped on branch switch

**Priority**: medium
**Status**: Done
**Category**: reliability
**Epic**: Chat Hardening
**Sprint**: 5
**Agent**: scotty
**Complexity**: XS

## Description

When switching branches mid-stream, `branchWillSwitchObserver` correctly:
- Writes a snapshot checkpoint
- Unsubscribes from `ActiveStreamRegistry`

But it does NOT call `stopStreamBatching()`. The 10fps `streamFlushTimer` keeps firing on the old ViewModel until it is deallocated by SwiftUI.

Since the timer is weakly captured and the old ViewModel is bound to a view that SwiftUI is destroying, this is not a crash or a correctness bug — the timer calls are no-ops once `pendingTokenBuffer` is empty. However:

- The old ViewModel may stay alive longer than expected if something else holds a reference (e.g. a Task still in flight, the GRDB observation block)
- During that window, `flushPendingTokens()` keeps calling `GlobalStreamRegistry.shared.appendContent()` with the old branch's content — potentially causing stale content to appear in the Command Center's live streams view

## Files to Modify

- **Modify**: `Sources/Features/Document/DocumentEditorView.swift` — `branchWillSwitchObserver` handler (~line 864)

## Requirements

- Call `stopStreamBatching()` in the `branchWillSwitch` observer handler, after unsubscribing from the registry
- Ensure `pendingTokenBuffer` is cleared at the same time

## Acceptance Criteria

- [ ] `stopStreamBatching()` is called when a branch switch is detected
- [ ] `pendingTokenBuffer` is empty after the switch
- [ ] No timer-driven side effects after the old branch loses focus
