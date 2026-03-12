# TASK-133: MemoryService + DaemonService concurrency fixes

**Priority**: medium
**Status**: Done
**Category**: concurrency
**Source**: QA Audit Wave 6

## Description
1. MemoryService.contextMessageLimit accesses cachedMessageLimit/limitLastComputed without lock protection (only tableExistsCache is locked)
2. DaemonService pendingTasks.append races between timer callbacks — append should be inside the @MainActor task, not a separate hop

## Fix
1. Protect cachedMessageLimit with cacheLock
2. Move pendingTasks.append into the first @MainActor block

## Acceptance Criteria
- [x] No data races in MemoryService cache access
- [x] pendingTasks modifications are serialized
