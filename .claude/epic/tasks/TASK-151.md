# TASK-151: Event Rules UI — Settings Sheet

**Priority**: medium
**Status**: Done
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 3
**Agent**: data
**Complexity**: M
**Dependencies**: TASK-150

## Description

Settings UI for creating, editing, enabling/disabling, and deleting event trigger rules. Accessible from Command Center header and Settings.

## Files to Create

- **Create**: `Sources/Features/CommandCenter/EventRulesSheet.swift`

## Layout

```
┌─ Event Rules ─────────────────────────────── [+ New Rule] ─┐
│                                                               │
│ ☑ Build failure auto-fix                          [Edit] [×] │
│   When: build_staleness signal                                │
│   Then: Dispatch geordi                                       │
│   Last triggered: 2 hours ago (3 times total)                │
│                                                               │
│ ☑ Error loop intervention                         [Edit] [×] │
│   When: 5+ consecutive errors                                 │
│   Then: Dispatch worf                                         │
│   Last triggered: never                                       │
│                                                               │
│ ☐ Stale ticket nudge (disabled)                   [Edit] [×] │
│   When: stale_ticket signal                                   │
│   Then: Create attention event                                │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

## Rule Editor (modal)

- Name field
- Trigger type picker (dropdown)
- Trigger config: dynamic form based on trigger type
  - heartbeat_signal → signal category picker
  - error_count → number stepper
  - build_failure → project picker (or "any")
  - session_complete → agent picker (or "any")
- Action type picker
  - dispatch_agent → agent picker + project picker + prompt template text area
  - notify → message text field
  - run_command → command text field + working directory
- Cooldown minutes (default 30)
- Require confirmation toggle

## Access Points

- Button in Command Center header (gear icon next to Crew/Dispatch buttons)
- Settings > Automation tab

## Acceptance Criteria

- [ ] List shows all rules with enable/disable toggle
- [ ] New Rule creates a rule with editor
- [ ] Edit modifies existing rule
- [ ] Delete removes rule (with confirmation)
- [ ] Enable/disable toggle updates DB immediately
- [ ] "Last triggered" shows relative time or "never"
- [ ] Trigger count displayed
