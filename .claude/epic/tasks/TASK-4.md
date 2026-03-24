# TASK-4: pendingAssistantContent single-slot stale across rapid back-to-back responses

**Status:** cancelled
**Priority:** high
**Area:** message-pipeline

## Problem

`pendingAssistantContent` is a single `String?`. If two responses complete in quick succession:
1. Response 1 completes → slot set to "Response 1"
2. Response 2 completes → slot OVERWRITTEN to "Response 2"
3. GRDB delivers Response 1 → slot mismatch → slow-path finds wrong nil-id section
4. Response 1 appears as a duplicate second bubble

**Location:** `DocumentEditorView.swift` lines ~1223, 1241, 1818–1821

## Fix

Change to `Set<String>`. Insert on complete, remove on match, clear on session change.

## Acceptance Criteria
- 3 rapid messages with no wait — all three responses render exactly once
TASK-4 cancelled
