# TASK-099: HIGH — Edge case crashes: rapid sends, branch delete during stream, fork from deleted branch

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** isSending guard prevents rapid double-sends, stream cancelled on branch delete, parent validation on fork
**Priority:** high
**Assignee:** —
**Phase:** Stability
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Multiple crash/data-loss scenarios under concurrent or rapid user actions:

### 1. Rapid send DB lock contention
10 messages in <5 seconds exceeds busy_timeout (5000ms). Writes fail silently or throw uncaught exceptions. Message #6+ may not persist.

### 2. Delete tree/branch while streaming
`TreeStore.deleteTree()` deletes branch rows. Streaming ViewModel tries `getBranch(branchId)` → nil → crash on force-unwrap or stale state. FK constraint violations if streaming ViewModel inserts into canvas_dispatches.

### 3. Fork from deleted branch
User opens ForkMenu, deletes source branch before confirming fork. `TreeStore.createBranch(parentBranch:)` → parent ID doesn't exist → FK violation → unhandled error.

### 4. Message deduplication race
Stream arrives from daemon while ValueObservation fires from GRDB simultaneously. Both `applyMessages()` and direct section append create duplicate UI sections.

### 5. Delete branch with pending ForkMenu
ForkMenu references branch that was just deleted. No dismissal on branch deletion.

## Acceptance Criteria

- [ ] Sends queued behind serial actor with retry on busy_timeout
- [ ] Tree/branch deletion checks for active streams and cancels them first
- [ ] ForkMenu dismissed if source branch is deleted
- [ ] Branch deletion uses soft-delete or validates no active references
- [ ] Message deduplication uses content hash window (10s) to prevent duplicates
- [ ] All tree/branch mutations validate existence before FK operations

## Files

- `Sources/Core/Database/DatabaseManager.swift` (line 36)
- `Sources/Core/Database/TreeStore.swift` (lines 225, 417)
- `Sources/Features/Canvas/ForkMenu.swift`
- `Sources/Features/Document/DocumentEditorView.swift` (lines 888-945, 1285-1370)
