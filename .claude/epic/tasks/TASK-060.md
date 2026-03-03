# TASK-060: feat: Share Extension

**Status:** Done
**Priority:** Medium
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Add a Share Extension so users can share text/URLs from any app into World Tree as a new message.

## Acceptance Criteria

- [ ] Share Extension target added to Xcode project
- [ ] Accepts `NSExtensionActivationSupportsText` and `NSExtensionActivationSupportsWebURLWithMaxCount`
- [ ] Shows tree/branch picker to choose destination
- [ ] Sends content as a message to selected branch
- [ ] Uses App Groups to share Keychain auth token with main app

## Implementation Notes

- Extension bundle ID: `com.forgeandcode.worldtree.share`
- App Group: `group.com.forgeandcode.worldtree`
- Shared Keychain access group for auth token
- UI: simple picker sheet — no heavy SwiftUI needed
