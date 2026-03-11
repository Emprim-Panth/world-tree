# TASK-091: CRITICAL — Orphaned streaming tasks on window close

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** streamTask.cancel() in onDisappear + deinit, GlobalStreamRegistry cleanup
**Priority:** critical
**Assignee:** —
**Phase:** Stability
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

When user closes a window or kills the app while a response is streaming, the `streamTask` in DocumentEditorView continues running in the background. It consumes API tokens, writes to the database, and is never cleaned up.

### Root cause
- `deinit` (line 583) cancels `streamFlushTimer` but NOT `streamTask`
- `GlobalStreamRegistry` keeps a reference, preventing cleanup
- The for-await loop continues consuming tokens from the API

### Related issues
- `ProcessingRegistry` and `GlobalStreamRegistry` never cleaned up on tree deletion
- If a tree is deleted while streaming, branch ID persists in both registries
- Sidebar shows "processing" indicator for non-existent branches

## Acceptance Criteria

- [ ] `streamTask` cancelled in deinit
- [ ] `GlobalStreamRegistry.endStream()` called on view teardown
- [ ] `ProcessingRegistry.deregister()` called on view teardown
- [ ] `TreeStore.deleteTree()` notifies registries to clean up dead branch IDs
- [ ] No orphaned tasks after window close (verify with Instruments)

## Files

- `Sources/Features/Document/DocumentEditorView.swift` (lines 583, 1279-1282, 1285-1370)
- `Sources/Shared/ProcessingRegistry.swift`
- `Sources/Shared/GlobalStreamRegistry.swift`
- `Sources/Core/Database/TreeStore.swift` (line 225)
