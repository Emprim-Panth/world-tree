# TASK-149: Conflict Warning Banner UI

**Priority**: medium
**Status**: Done
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 2
**Agent**: data
**Complexity**: S
**Dependencies**: TASK-148

## Description

Visual warning banner that appears in the AttentionPanel when file conflicts are detected. Shows which file, which agents, and provides context to help decide whether to intervene.

## Files to Create

- **Create**: `Sources/Features/CommandCenter/ConflictWarningBanner.swift`

## Component

```swift
struct ConflictWarningBanner: View {
    let conflict: ConflictDetector.FileConflict
    var onDismiss: (() -> Void)?
}
```

## Visual

```
┌─ ⚠️ FILE CONFLICT ──────────────────────────────────────────┐
│                                                                │
│  Sources/Core/Database/MigrationManager.swift                 │
│                                                                │
│  geordi (WorldTree) edited 2m ago                             │
│  scotty (WorldTree) edited 45s ago                            │
│                                                                │
│  Both agents are actively editing this file.                  │
│  Consider pausing one agent to avoid merge conflicts.         │
│                                                                │
│                                    [Dismiss]  [View in Diff]  │
└────────────────────────────────────────────────────────────────┘
```

- Orange/amber background tint
- File path in monospaced font
- Agent names with their project and last touch time
- "View in Diff" opens DiffReviewSheet for the more recent session

## Acceptance Criteria

- [ ] Shows file path, both agents, and touch timestamps
- [ ] Orange/amber visual treatment (not red — this is a warning, not an error)
- [ ] Dismiss acknowledges the underlying attention event
- [ ] "View in Diff" navigates to diff review
- [ ] Handles 3+ agents on same file (shows all)
