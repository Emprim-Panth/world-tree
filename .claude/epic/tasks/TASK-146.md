# TASK-146: Token & Cost Dashboard — UI

**Priority**: medium
**Status**: Done
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 2
**Agent**: data
**Complexity**: L
**Dependencies**: TASK-145

## Description

Visual dashboard showing token spend across sessions, projects, and time. Collapsible section in the Command Center between Agent Status Board and project grid.

## Files to Create

- **Create**: `Sources/Features/CommandCenter/TokenDashboardView.swift`

## Layout

```
┌─ 💰 TOKENS ──────────────────────── Today: 1.2M ── Week: 8.4M ─┐
│                                                                    │
│  Session Burn Rates                                                │
│  ┌────────────────────────────────────────────────────────┐       │
│  │ geordi/WorldTree  ████████░░░░  2,400 tok/min  145K   │       │
│  │ data/BookBuddy    ██████████░░  3,100 tok/min  210K   │       │
│  │ interactive/HHQ   ██░░░░░░░░░░    340 tok/min   28K   │       │
│  └────────────────────────────────────────────────────────┘       │
│                                                                    │
│  Context Windows                                                   │
│  ┌────────────────────────────────────────────────────────┐       │
│  │ geordi    ░░░░░░░░░░░░▓▓▓▓ 68%  136K / 200K          │       │
│  │ data      ░░░░░░░░▓▓▓▓▓▓▓▓ 82%  164K / 200K  ⚠️      │       │
│  │ interact  ░░░░░░░░░░░░░░░░ 12%   24K / 200K          │       │
│  └────────────────────────────────────────────────────────┘       │
│                                                                    │
│  Daily Trend (7d)                                                  │
│  ┌────────────────────────────────────────────────────────┐       │
│  │     ╷                                                   │       │
│  │  █  █                                                   │       │
│  │  █  █  █     █                                         │       │
│  │  █  █  █  █  █  █  ▄                                   │       │
│  │  M  T  W  T  F  S  S                                   │       │
│  └────────────────────────────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────────┘
```

## Visual Components

1. **Header**: Section title + today's total + week total
2. **Burn Rate Bars**: Horizontal bars per session, color-coded (green normal, orange high, red very high)
3. **Context Windows**: Horizontal progress bars with green/yellow/red coloring
4. **Daily Trend**: Simple bar chart using SwiftUI rectangles (no Charts framework needed)

## Data Flow

- Uses `TokenStore.shared` methods from TASK-145
- Refreshes on appear + every 30 seconds while visible
- No GRDB observation needed — polling is fine for aggregate stats

## Acceptance Criteria

- [ ] Header shows accurate daily and weekly totals
- [ ] Burn rate bars scale relative to highest rate
- [ ] Context window bars use correct color thresholds (green <70%, yellow 70-90%, red >90%)
- [ ] Daily trend shows 7 bars, correctly scaled
- [ ] Section collapses/expands (matching StarfleetActivitySection pattern)
- [ ] Renders correctly with 0 sessions (empty state)
- [ ] Performance: no visible lag from aggregate queries
