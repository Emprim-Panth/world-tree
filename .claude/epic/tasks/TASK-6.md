# TASK-6: Recovery append missing pendingAssistantContent update — double render on GRDB race

**Status:** cancelled
**Priority:** high
**Area:** message-pipeline

## Problem

`appendLatestPersistedAssistantMessage()` appends a recovered message with a real messageId but never sets `pendingAssistantContent`. When GRDB fires shortly after, `matchingPending` is false, the slow-path finds no nil-id match (recovery used a real ID), and the message renders a second time.

**Location:** `DocumentEditorView.swift` lines ~886–891

## Fix

After recovery append: `self.pendingAssistantContent = lastAssistant.content`

## Acceptance Criteria
- Simulated stream interruption + recovery → message renders exactly once after full DB delivery
TASK-6 cancelled
