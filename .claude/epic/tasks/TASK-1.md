# TASK-1: Polling fallback task in-flight after timer invalidate — cross-branch ghost messages

**Status:** cancelled
**Priority:** critical
**Area:** message-pipeline

## Problem

When navigating between branches, `refreshTimer?.invalidate()` stops future firings but any `Task` already dispatched to the main actor is still in-flight. That stale Task calls `applyMessages()` with messages from the old branch's sessionId — and because the new ViewModel's `seenMessageIds` is empty, those messages pass the dedup guard and render as phantom bubbles.

**Location:** `DocumentEditorView.swift` — `startExternalRefreshTimer()` lines ~1335–1367

## Root Cause

```swift
refreshTimer = Timer.scheduledTimer(...) { [weak self] _ in
    Task { @MainActor [weak self] in   // Task queued, runs after invalidate()
        guard let self, self.usePollingFallback else { return }
        self.applyMessages(messages)   // fires with stale sid
    }
}
```

`invalidate()` prevents new firings but cannot cancel a `Task` already queued.

## Fix

Introduce a `pollingGeneration: Int` counter. Increment on `loadDocument()`. Task captures its generation at creation and bails if `self.pollingGeneration != capturedGeneration`.

## Acceptance Criteria
- Rapidly switching branches 5+ times does not surface messages from a previous branch
TASK-1 cancelled
