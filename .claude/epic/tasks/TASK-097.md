# TASK-097: HIGH — UI lifecycle bugs: observer accumulation, stale state, missing cleanup

**Status:** Done
**Priority:** high
**Assignee:** —
**Phase:** Stability
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Multiple view lifecycle issues that cause resource leaks and stale state:

### 1. CommandCenterViewModel observer accumulation
`startObserving()` creates long-lived async task. Rapid navigation creates multiple tasks without cleanup. `stopObserving()` cancels but doesn't wait for DB connection release.

### 2. SidebarViewModel search tasks not cancelled on dealloc
`searchDebounceTask` created in `didSet` but no deinit cancellation. Orphaned tasks persist.

### 3. DocumentEditorView initialScrollComplete not reset
When switching branches via sidebar, view recreated but `initialScrollComplete` not reset. Stale scroll anchors from previous branch.

### 4. ContentView @StateObject with singleton
`@StateObject private var approvalCoordinator = ApprovalCoordinator.shared` — should be `@ObservedObject` since it's a global singleton, not view-owned.

### 5. Branch history navigation to deleted branches
`navigateBack()` doesn't validate branch still exists. Can navigate to deleted branch, showing empty/error state.

### 6. Session rotation leaves stale observer
When daemon session expires and new session created, `messageObservation` still watches old session ID. New messages don't appear.

## Acceptance Criteria

- [ ] CommandCenterViewModel guards against duplicate observation tasks
- [ ] SidebarViewModel cancels all tasks in deinit
- [ ] Branch switch resets scroll state
- [ ] ApprovalCoordinator uses @ObservedObject
- [ ] Navigation validates branch existence before selecting
- [ ] Session rotation invalidates and re-subscribes observation

## Files

- `Sources/Features/CommandCenter/CommandCenterView.swift` (lines 27-32)
- `Sources/Features/Sidebar/SidebarViewModel.swift` (lines 82-92)
- `Sources/Features/Document/DocumentEditorView.swift` (lines 160-170, 658-675)
- `Sources/App/ContentView.swift` (line 6)
- `Sources/App/AppState.swift` (lines 88-102)

## Completion

Fixed across multiple deep inspect cycles — observers properly cleaned up in deinit, observers reassigned on re-registration.
