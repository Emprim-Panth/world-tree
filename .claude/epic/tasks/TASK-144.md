# TASK-144: Session Health Badge UI Component

**Priority**: medium
**Status**: Done
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 2
**Agent**: data
**Complexity**: S
**Dependencies**: TASK-143

## Description

Small visual indicator component that renders a session's health as a colored badge with optional tooltip showing factor breakdown.

## Files to Create

- **Create**: `Sources/Features/CommandCenter/SessionHealthBadge.swift`

## Component API

```swift
struct SessionHealthBadge: View {
    let health: SessionHealth
    var showDetails: Bool = false  // expand to show factor breakdown
}
```

## Visual

- Compact mode: 8x8 filled circle (red/yellow/green) with subtle glow
- Expanded mode (on hover or tap): Popover showing:
  ```
  Health: 0.72 (Green)
  ─────────────────
  Errors:    ████████░░ 0.8
  Burn Rate: ██████░░░░ 0.6
  Context:   █████████░ 0.9
  Files:     ██████████ 1.0
  ```
- Each factor shown as a mini progress bar with its 0-1 value

## Integration Points

- Used by `AgentStatusCard` (TASK-137) in the footer row
- Used by `CompassProjectCard` to show aggregate project health (average of active sessions)

## Acceptance Criteria

- [ ] Red/yellow/green renders correctly for all HealthLevel values
- [ ] Hover popover shows factor breakdown
- [ ] Graceful when health is nil (shows gray dot)
- [ ] Compact enough for inline use (8x8pt minimum)
