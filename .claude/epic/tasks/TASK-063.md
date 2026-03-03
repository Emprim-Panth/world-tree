# TASK-063: feat: Widgets (WidgetKit)

**Status:** Pending
**Priority:** Low
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Home Screen and Lock Screen widgets showing recent conversation summary and quick-send shortcut.

## Widget Types

1. **Small** — Connection status + last message timestamp
2. **Medium** — Last 2 message snippets from active branch
3. **Lock Screen (accessory)** — "Last message 5m ago" + tap to open

## Acceptance Criteria

- [ ] Widget extension target added
- [ ] Timeline provider uses App Group shared UserDefaults for last-message cache
- [ ] Tapping widget deep-links to correct tree/branch
- [ ] Widgets update when main app receives new messages (via App Group write)
- [ ] Placeholder/redacted view during loading

## Implementation Notes

- App Group: `group.com.forgeandcode.worldtree`
- Widget bundle ID: `com.forgeandcode.worldtree.widget`
- No WebSocket in widget — read-only from shared cache
- `WidgetCenter.shared.reloadAllTimelines()` called after new message received
