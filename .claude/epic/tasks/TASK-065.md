# TASK-065: feat: Apple Watch companion app

**Status:** Done
**Priority:** Medium
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Minimal watchOS companion that shows recent messages and lets the user send a voice dictation.

## Acceptance Criteria

- [ ] watchOS target added to Xcode project
- [ ] Complication shows last message timestamp
- [ ] Main watch app shows last 5 messages in active branch
- [ ] Dictation button: tap → dictation sheet → send on confirm
- [ ] Watch ↔ iPhone sync via `WatchConnectivity` (WCSession)
- [ ] Notification on watch mirrors iPhone notification

## Implementation Notes

- `WKInterfaceController` or SwiftUI on watchOS 7+
- `WCSession`: iPhone is the WS client; Watch sends commands to iPhone which relays
- No direct WebSocket on Watch (battery + API not available)
- Message sync: iPhone pushes last 5 messages to Watch via `transferUserInfo`
- Dictation: `WKInterfaceController.presentTextInputController`
