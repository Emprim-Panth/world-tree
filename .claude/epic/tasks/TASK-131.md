# TASK-131: Missing FK cascade for branch-dependent tables

**Priority**: medium
**Status**: ready
**Category**: data-integrity
**Source**: QA Audit Wave 6

## Description
Migration v18 cleans orphans only for canvas_branch_tags and canvas_api_state. Other branch-dependent tables lack cascade: canvas_context_checkpoints, canvas_token_usage, canvas_jobs, pen_frame_links.

## Fix
Add cleanup triggers or extend deleteTreeContents/deleteBranch to cascade to all branch-dependent tables.

## Acceptance Criteria
- [ ] All branch-dependent tables cleaned up on branch/tree delete
- [ ] No orphaned rows accumulate over time
