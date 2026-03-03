# TASK-061: feat: Handoff / Continuity

**Status:** Done
**Priority:** Medium
**Assignee:** Cortana
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Enable Handoff so a conversation open on iPhone continues seamlessly on Mac (and vice versa).

## Acceptance Criteria

- [ ] `NSUserActivity` created when user opens a branch
- [ ] Activity type: `com.forgeandcode.worldtree.branch`
- [ ] Payload: treeId + branchId
- [ ] macOS World Tree handles `application(_:continue:restorationHandler:)` and navigates to the branch
- [ ] iOS also handles continuation from macOS

## Implementation Notes

- `NSUserActivity.isEligibleForHandoff = true`
- Activity updated on `selectBranch()` in WorldTreeStore
- macOS: `onContinueUserActivity` modifier in SwiftUI or `AppDelegate`
- Requires matching associated domains or activity type in both targets
