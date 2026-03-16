# TASK-157: CRITICAL — Stream Recovery State Machine + Auto-Resume Reliability

**Priority**: critical
**Status**: Done
**Category**: error-recovery
**Epic**: Audit Follow-Up
**Sprint**: 4
**Agent**: data
**Complexity**: L
**Dependencies**: TASK-050, TASK-099

## Description

World Tree recovers interrupted stream text on launch, but the auto-resume path is still a one-shot in-memory handshake. `WorldTreeApp` inserts a recovered partial and flips `DocumentEditorViewModel.pendingAutoResume`, while `DocumentEditorViewModel.autoResumeIfNeeded()` checks that flag once after a 2-second delay and then never retries.

That means recovery can still be missed if the session view loads before the recovery task finishes, if a draft is present, or if the branch is not open at the exact moment the one-shot check runs. This matches the observed failure mode where a session is clearly interrupted but never actually resumes.

Replace the loose flag with an explicit recovery state machine that survives timing races and only clears when a continuation has either been sent successfully or deliberately dismissed.

## Files to Modify

- **Modify**: `Sources/App/WorldTreeApp.swift`
- **Modify**: `Sources/Features/Document/DocumentEditorView.swift`
- **Modify**: `Sources/Shared/ActiveStreamRegistry.swift`
- **Modify**: `Sources/Core/Cache/StreamCacheManager.swift`
- **Create**: `Tests/SmokeTests/StreamRecoveryTests.swift`

## Requirements

- Introduce a durable pending-recovery record per session instead of an in-memory-only `Set<String>`
- Retry auto-resume when the document becomes safe to resume, not just once on load
- Keep recovered partial content and continuation intent linked to the same lifecycle
- Add operator-visible recovery state so interrupted sessions are obvious instead of silent
- Ensure recovery is idempotent: one interrupted stream yields one recovered partial and one continuation prompt

## Acceptance Criteria

- [x] Interrupted responses always recover partial text exactly once
- [x] Auto-resume still fires if recovery finishes after the document view loads
- [x] Draft text or temporary UI state defers resume instead of losing it permanently
- [x] Recovery state clears only after successful continuation or explicit dismissal
- [x] Tests cover delayed launch ordering, repeated app opens, and interrupted-stream retry behavior

## Resolution

Implemented a durable `StreamRecoveryStore` backed by `UserDefaults`, replaced the in-memory auto-resume set, and wired `DocumentEditorViewModel` to retry resume whenever the session becomes safe instead of relying on a one-shot launch timing window.
