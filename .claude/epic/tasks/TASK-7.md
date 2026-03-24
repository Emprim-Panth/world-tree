# TASK-7: Notification observer removal not atomic — gap window for duplicate or missed events

**Status:** cancelled
**Priority:** medium
**Area:** reliability

## Problem

In `loadDocument()`, old observers are removed one-by-one then new ones registered ~100 lines later. A notification delivered in that gap is silently dropped. If `removeObserver` fails silently, old + new observers both remain active → duplicate processing.

**Location:** `DocumentEditorView.swift` lines ~652–821

## Fix

Switch to `NotificationCenter.Publisher` + `Set<AnyCancellable>`. Replacing the set is atomic; no gap window possible.

## Acceptance Criteria
- `loadDocument()` called 20× rapidly — no notification processed twice, none dropped
TASK-7 cancelled
