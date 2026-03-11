# TASK-113: Empty-state handling gaps

**Priority**: low
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Empty-state placeholders for sidebar tree list and search view
**Category**: ux
**Source**: QA Audit Wave 2

## Description
Several views don't handle empty states gracefully:
- Empty tree list shows blank area instead of onboarding prompt
- Empty message list in a branch shows nothing
- Empty search results lack "no results" feedback
- Empty ticket list in Command Center shows blank space

## Acceptance Criteria
- [ ] Tree list shows "Create your first conversation" prompt when empty
- [ ] Empty branch shows contextual message
- [ ] Search shows "No results for ..." with suggestions
- [ ] Empty ticket list shows appropriate placeholder
