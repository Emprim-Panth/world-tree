# TASK-056: feat: tree/branch management on mobile (rename, delete)

**Status:** Done
**Priority:** High
**Assignee:** Cortana
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Add rename/delete to TreeListView and BranchesListView via swipe actions.
Requires adding rename_tree, delete_tree, rename_branch, delete_branch WS commands on the server.

## Acceptance Criteria

- [x] Swipe-left on tree row shows Rename and Delete actions
- [x] Swipe-left on branch row shows Rename and Delete actions
- [x] Server handlers added for rename_tree, delete_tree, rename_branch, delete_branch
- [x] Delete shows confirmation alert before executing
- [x] After rename, tree/branch list refreshes from server

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-03 | Cortana | Implemented |
