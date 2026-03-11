# TASK-127: WTCommandBridge unsafe nonisolated memory access

**Priority**: high
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Added comment clarifying lock coverage; lock already covers full access window correctly
**Category**: concurrency
**Source**: QA Audit Wave 6

## Description
WTCommandBridge has `nonisolated(unsafe)` properties `fileHandle` and `bytesRead` (lines 50-51) that are accessed from nonisolated `readNewLines()` while the @MainActor class can also access them. The ioLock doesn't cover the full access window.

## Fix
Extend ioLock to cover entire fileHandle and bytesRead access in readNewLines(), not just partial operations.

## Acceptance Criteria
- [ ] ioLock held for entire duration of fileHandle/bytesRead access
- [ ] No data race possible between readNewLines() and MainActor access
