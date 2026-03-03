# TASK-058: feat: iOS Live Activities & Dynamic Island

**Status:** Done
**Priority:** Medium
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Show active AI response as a Live Activity on the Lock Screen and Dynamic Island.
While Cortana is streaming a response, the Dynamic Island shows an animated indicator.
On Lock Screen: shows conversation name + "Cortana is thinking…" or token preview.

## Acceptance Criteria

- [ ] Live Activity widget defined in ActivityKit extension
- [ ] Activity starts when `isStreaming` becomes true
- [ ] Activity updates with token preview (last 80 chars of streaming text)
- [ ] Activity ends when `message_complete` received
- [ ] Works on Dynamic Island (iPhone 14 Pro+) and compact/minimal presentations

## Implementation Notes

- Requires `NSSupportsLiveActivities: YES` in Info.plist
- Requires Widget Extension target in Xcode project
- ActivityKit framework (iOS 16.1+)
- Update frequency: throttle to max 1 update/sec to avoid rate limiting
