# TASK-108: Search navigation missing from history

**Priority**: medium
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Search results use Button instead of onTapGesture for reliable navigation
**Category**: bug
**Source**: QA Audit Wave 2

## Description
GlobalSearchView shows search results but doesn't call `selectBranch()` when a result is tapped. Users can find messages via search but can't navigate to them in the tree.

## Acceptance Criteria
- [ ] Tapping a search result navigates to the containing branch
- [ ] Selected branch scrolls into view in sidebar
- [ ] Search result message is highlighted/scrolled to in the conversation
