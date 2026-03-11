# TASK-101: MEDIUM — UI/UX gaps: missing loading states, error feedback, confirmation dialogs

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** Delete confirmation dialogs on BranchLayoutView, error alerts surfaced from ViewModel, loading ProgressView
**Priority:** medium
**Assignee:** —
**Phase:** UX
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Multiple UX issues where the app doesn't communicate state to the user:

### Missing loading states
1. Sidebar search shows no loading indicator while content search runs
2. CompassProjectCard has no skeleton state while Compass data loads
3. Global search dialog shows no results indicator during query

### Missing error feedback
1. Tree creation failure silently closes sheet — no error shown
2. Dispatch creation failure not surfaced to user
3. Failed daemon connection shows no retry option

### Missing confirmation dialogs
1. Active dispatch cancel — single click kills long-running work, no confirmation
2. No confirmation on tree deletion with active streams

### Keyboard accessibility
1. Code block copy button invisible (opacity: 0) when not hovering — keyboard users can't see or reach it
2. Global search doesn't return focus to document on dismiss

### Layout
1. BranchColumn hardcoded to 500px — breaks on MacBook Air / narrow displays
2. DispatchSheet TextEditor has no maxHeight — grows indefinitely with large input
3. DocumentEditorView padding can cause content overflow on narrow views

## Acceptance Criteria

- [ ] Loading indicators for all async operations (search, data load, dispatch)
- [ ] Error alerts for tree creation, dispatch creation failures
- [ ] Confirmation dialog before cancelling active dispatches
- [ ] Code copy button visible at reduced opacity for keyboard users
- [ ] BranchColumn uses adaptive sizing (minWidth: 300, maxWidth: .infinity)
- [ ] DispatchSheet TextEditor maxHeight: 300
- [ ] Focus restoration after search dialog dismiss

## Files

- `Sources/Features/Sidebar/SidebarView.swift` (lines 178-181, 764-776)
- `Sources/Features/CommandCenter/ActiveWorkSection.swift`
- `Sources/Features/CommandCenter/CompassProjectCard.swift`
- `Sources/Features/CommandCenter/DispatchSheet.swift` (lines 64-72)
- `Sources/Shared/Components/CodeBlockView.swift` (lines 86-89)
- `Sources/Features/Document/SingleDocumentView.swift` (line 78)
- `Sources/Features/Dashboard/GlobalSearchView.swift`
