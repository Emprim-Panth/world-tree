# TASK-059: feat: Siri & Shortcuts integration

**Status:** Done
**Priority:** Medium
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Expose World Tree actions as App Intents for use with Siri and the Shortcuts app.

## Acceptance Criteria

- [ ] "Send message to World Tree" intent — accepts text, sends to current branch
- [ ] "Open tree [name]" intent — navigates to named tree on launch
- [ ] "Create new tree" intent — opens NewTreeSheet pre-filled with spoken name
- [ ] Intents appear in Shortcuts app under "World Tree"
- [ ] Siri phrase triggers work: "Hey Siri, ask World Tree about X"

## Implementation Notes

- App Intents framework (iOS 16+)
- `AppShortcutsProvider` for auto-discovered phrases
- Donated to `INInteraction` after each send for learning
