# TASK-5: Boundary-shift guard silently skips non-integer message IDs

**Status:** cancelled
**Priority:** high
**Area:** message-pipeline

## Problem

The boundary-shift guard (commit 2b36363) converts IDs to `Int`. If any message ID is a UUID, `Int(msg.id)` returns nil and the guard is skipped — the message passes through even if older than the current window.

**Location:** `DocumentEditorView.swift` lines ~1184–1193

```swift
if maxSeenIntId > 0, let msgIntId = Int(msg.id), msgIntId <= maxSeenIntId {
    // UUID IDs always skip this block
}
```

## Fix

Track `lastSeenTimestamp: Date` alongside `maxSeenIntId`. For non-integer IDs, fall back to `msg.timestamp <= lastSeenTimestamp`.

## Acceptance Criteria
- Messages with UUID-format IDs older than current window do not re-appear
- Integer-ID behavior unchanged
TASK-5 cancelled
