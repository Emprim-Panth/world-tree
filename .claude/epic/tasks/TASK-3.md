# TASK-3: NERVE factory pipeline messages not filtered — appear as phantom chat bubbles

**Status:** cancelled
**Priority:** critical
**Area:** message-pipeline

## Problem

The internal message filter (commit 45d5150) only covers `[TOOL:...]`, `[RESPONSE_COMPLETE]`, and `[PRE_COMPACT]`. Commit 9518050 added the NERVE factory pipeline with additional hook markers. Any new format not in the hardcoded list passes the filter and renders as a phantom assistant bubble.

**Location:** `DocumentEditorView.swift` lines ~1199–1213

## Fix

1. Audit cortana-core for all marker formats written to the DB
2. Expand filter to cover all — or add a bracket-prefix heuristic: any system/assistant message whose content is `[UPPERCASE_WORD...]` is treated as internal
3. Add debug logging when a message is filtered

## Acceptance Criteria
- No cortana-core pipeline marker appears in the chat UI
- Each known marker format is verified suppressed
TASK-3 cancelled
