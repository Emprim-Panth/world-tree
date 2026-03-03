# TASK-062: feat: Notification Reply (reply from lock screen)

**Status:** Done
**Priority:** Medium
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

When Cortana sends a response notification, the user can reply directly from the lock screen
without opening the app. Reply text is sent as a new message to the same branch.

## Acceptance Criteria

- [ ] Notification category "ASSISTANT_RESPONSE" registered with text-input action "Reply"
- [ ] `UNTextInputNotificationAction` identifier: "REPLY"
- [ ] App extension or background task handles reply → sends WebSocket message
- [ ] Notification updated to show "Sent" after reply dispatched
- [ ] Works when app is in background or terminated

## Implementation Notes

- `UNUserNotificationCenterDelegate` handles action in app delegate
- Background task: if WS not connected, reconnect → send → disconnect
- Branch context: branchId stored in notification `userInfo`
