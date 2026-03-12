# TASK-137: AgentStatusCard — Individual Agent Card Component

**Priority**: high
**Status**: Todo
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: data
**Complexity**: M
**Dependencies**: TASK-134

## Description

SwiftUI component for a single agent's status card within the Agent Status Board. Self-contained, reusable, driven entirely by an `AgentSession` model.

## Files to Create

- **Create**: `Sources/Features/CommandCenter/AgentStatusCard.swift`

## Component API

```swift
struct AgentStatusCard: View {
    let session: AgentSession
    let healthScore: SessionHealth?  // from TASK-143, optional until built
    var onTap: (() -> Void)?
}
```

## Visual Elements (top to bottom)

1. **Header row**: Agent name badge (colored circle + name) | Status pill (icon + label) | Duration
2. **Project**: Project name, dimmed
3. **Task**: Current task/goal, 2-line max, truncated
4. **Current file**: Monospaced, prefixed with diamond (◆), 1-line
5. **Context bar**: Thin horizontal bar, green < 70%, yellow 70-90%, red > 90%
6. **Footer row**: Token count (compact: "45K") | Error count (red if > 0) | Health badge (TASK-143, placeholder dot)

## Status Icons

| Status | SF Symbol | Color |
|--------|-----------|-------|
| starting | play.circle | gray |
| thinking | brain | blue |
| writing | pencil.line | green |
| tool_use | terminal | cyan |
| waiting | hourglass | orange |
| stuck | exclamationmark.triangle | red |
| idle | moon.zzz | gray |
| completed | checkmark.circle | green |
| failed | xmark.circle | red |

## Accessibility

- Each card is a single accessible element with combined children
- Label: "{agent} on {project}: {status}, {duration}, {token count} tokens"
- Hint: "Tap to inspect" (when tappable)

## Acceptance Criteria

- [ ] All 9 status values render with correct icon and color
- [ ] Context bar color transitions at 70% and 90% thresholds
- [ ] Token count formats correctly: <1K raw, 1K-999K as "XK", 1M+ as "X.XM"
- [ ] Card has consistent height regardless of content length (fixed min height)
- [ ] Dark mode renders correctly
- [ ] VoiceOver reads coherent summary
