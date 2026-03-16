# TASK-158: HIGH — Stream Cancellation Deduplication + Single-Writer Persistence

**Priority**: high
**Status**: Done
**Category**: error-recovery
**Epic**: Audit Follow-Up
**Sprint**: 4
**Agent**: data
**Complexity**: M
**Dependencies**: TASK-157

## Description

The stream cancellation path is still inconsistent. `processUserInput()` correctly treats `ActiveStreamRegistry` as the single writer for interrupted partials, but `DocumentEditorViewModel.cancelStream()` cancels through the registry and then writes the same partial back to `MessageStore` again.

That creates a duplicate-assistant risk on manual cancel and leaves stream-cache cleanup split across multiple places. World Tree needs one canonical cancellation path with one canonical writer, not two code paths racing to be helpful.

## Files to Modify

- **Modify**: `Sources/Features/Document/DocumentEditorView.swift`
- **Modify**: `Sources/Shared/ActiveStreamRegistry.swift`
- **Modify**: `Sources/Core/Cache/StreamCacheManager.swift`
- **Create**: `Tests/SmokeTests/StreamCancellationTests.swift`

## Requirements

- Make `ActiveStreamRegistry` the only component allowed to persist cancelled partial output
- Refactor manual cancel and mid-stream preemption to share the same cleanup rules
- Close or retire stream cache files in exactly one place
- Add regression coverage for duplicate assistant-message prevention

## Acceptance Criteria

- [x] Manual cancel never creates duplicate assistant messages
- [x] Sending a second message mid-stream preserves the first partial exactly once
- [x] Stream temp files are cleaned up once per cancellation path
- [x] UI still shows the preserved partial without an extra DB write
- [x] Tests cover manual cancel, mid-stream interruption, and repeated cancel taps

## Resolution

Made `ActiveStreamRegistry` the sole writer for cancelled partials, moved stream-cache cleanup into the registry cancellation path, and refactored `DocumentEditorViewModel` to render the persisted partial instead of writing it a second time.
