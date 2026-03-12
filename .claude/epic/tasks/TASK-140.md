# TASK-140: Attention Panel UI

**Priority**: high
**Status**: Todo
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: data
**Complexity**: M
**Dependencies**: TASK-139

## Description

SwiftUI panel in the Command Center that displays attention events. Shows between the header and the Agent Status Board — only visible when there are unacknowledged events.

## Files to Create/Modify

- **Create**: `Sources/Features/CommandCenter/AttentionPanel.swift`
- **Modify**: `Sources/Features/CommandCenter/CommandCenterView.swift` — Insert AttentionPanel after header

## Layout

```
┌─ ⚠️ ATTENTION (3) ─────────────────────────── [Dismiss All] ─┐
│                                                                 │
│ 🔴 scotty stuck on Archon-CAD — no activity for 8 minutes     │
│    "Build system migration" · 180K tokens                [→]   │
│                                                                 │
│ 🟡 geordi approaching context limit on WorldTree (92%)         │
│    "Fix terminal watchdog" · 184K/200K tokens            [→]   │
│                                                                 │
│ 🟢 data completed BookBuddy dispatch — 3 files changed  [Review]│
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Visual Design

- Red background tint for critical events, orange for warnings, green for info
- Each row: severity icon | message | metadata | action button
- Action buttons:
  - "stuck" → Navigate to terminal / Restart
  - "completed" / "review_ready" → Open diff review (TASK-141)
  - "context_low" → Just informational, dismiss
  - "error_loop" → Navigate to terminal
  - "conflict" → Show file conflict detail
- Swipe to dismiss individual events
- "Dismiss All" button in header

## Animations

- Slide in from top when first event appears
- Fade out when last event dismissed
- New critical events pulse once

## Acceptance Criteria

- [ ] Panel only visible when unacknowledged events exist
- [ ] Severity colors render correctly (red/orange/green)
- [ ] Individual dismiss works (swipe or X button)
- [ ] "Dismiss All" acknowledges all events
- [ ] Panel disappears smoothly when last event dismissed
- [ ] Action buttons route to correct views
- [ ] Accessible — severity announced, actions labeled
