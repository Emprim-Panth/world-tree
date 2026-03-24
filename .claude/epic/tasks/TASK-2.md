# TASK-2: Polling timer captures stale sessionId — wrong branch messages appear

**Status:** cancelled
**Priority:** critical
**Area:** message-pipeline

## Problem

`startExternalRefreshTimer()` captures `let sid = sessionId` at timer creation. If the user navigates before the 2-second timer fires, the async `dbPool.read()` executes with the OLD `sid`, returning messages from the previous session. These are passed to `applyMessages()` on the new ViewModel.

**Location:** `DocumentEditorView.swift` lines ~1337, 1357

## Fix

Inside the Task, read `self.sessionId` (current) and bail if it differs from the captured `sid`: `guard sid == self.sessionId else { return }`.

## Acceptance Criteria
- Navigate branches 10× rapidly, no cross-session message bleed
TASK-2 cancelled
