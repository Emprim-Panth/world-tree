# TASK-100: MEDIUM — Tool output truncated to 200 chars in UI

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** AnthropicAPIProvider .prefix(200) changed to .prefix(4000)
**Priority:** medium
**Assignee:** —
**Phase:** Bug Fix
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

AnthropicAPIProvider truncates tool results to 200 characters when yielding `.toolEnd()` events (line 252):

```swift
result: String(result.content.prefix(200)),
```

The full result goes to the model (correct), but users can only see 200 chars in the UI. For bash commands, file listings, and structured data, this makes tool results unverifiable.

ClaudeCodeProvider uses 4000 chars — the two providers should match.

## Acceptance Criteria

- [ ] Tool result display matches ClaudeCodeProvider behavior (4000 char limit with truncation notice)
- [ ] Users can see full tool output or at least a meaningful preview
- [ ] Truncation notice shows how many chars were cut

## Files

- `Sources/Core/Providers/AnthropicAPIProvider.swift` (line 252)
