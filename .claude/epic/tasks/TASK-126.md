# TASK-126: Auto-naming branches

**Priority**: low
**Status**: done
**Category**: feature
**Source**: QA Audit Wave 4 — Feature Gap Analysis

## Description
Branches are currently unnamed or manually named. Add automatic branch naming based on conversation content (first user message summary or detected intent).

## Acceptance Criteria
- [x] Auto-generate branch name from first user message
- [x] Name updates if conversation topic shifts significantly
- [x] Names are concise (< 50 chars)
- [x] User can override auto-name at any time
