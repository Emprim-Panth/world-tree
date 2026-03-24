# TASK-8: Content dedup slow path is O(n²) — jank in long sessions

**Status:** cancelled
**Priority:** low
**Area:** performance

## Problem

Slow-path dedup in `applyMessages()` scans all assistant sections calling `String($0.content.characters)` for each — O(n) per message, O(n²) total. Sessions with 100+ messages cause visible jank on every observation delivery.

**Location:** `DocumentEditorView.swift` lines ~1231–1237

## Fix

Maintain a `Set<String>` of displayed content hashes. Check the set instead of scanning sections. Clear on session change.

## Acceptance Criteria
- applyMessages with 500 messages completes in < 5ms
TASK-8 cancelled
