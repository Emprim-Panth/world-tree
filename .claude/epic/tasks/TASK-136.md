# TASK-136: Agent Status Board View

**Priority**: critical
**Status**: Done
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: data
**Complexity**: L
**Dependencies**: TASK-135

## Description

Build the main Agent Status Board — a section in CommandCenterView that shows all active agents/sessions at a glance. Replaces the scattered dispatch/job/stream views with a unified, real-time board.

## Files to Create/Modify

- **Create**: `Sources/Features/CommandCenter/AgentStatusBoard.swift` — Main board view
- **Modify**: `Sources/Features/CommandCenter/CommandCenterView.swift` — Insert AgentStatusBoard between header and projectGrid, replacing LiveStreamsSection and ActiveWorkSection when agent_sessions data is available (graceful fallback)

## Layout Design

```
┌─ AGENT STATUS ──────────────────────────────────────────────┐
│                                                              │
│ ┌─ geordi ─────────────┐  ┌─ data ────────────────────────┐ │
│ │ 🔵 Thinking  · 4m32s │  │ 🟢 Writing   · 12m07s        │ │
│ │ WorldTree             │  │ BookBuddy                     │ │
│ │ Fix terminal watchdog │  │ Content filter UI             │ │
│ │ ◆ BranchTerminal...  │  │ ◆ FilterSettingsView.swift    │ │
│ │ ░░░░░░░░░░░░▓▓ 68%   │  │ ░░░░░░░░░▓▓▓▓▓▓ 82%         │ │
│ │ 45K tokens · 3 errors │  │ 120K tokens · 0 errors       │ │
│ └───────────────────────┘  └──────────────────────────────-┘ │
│                                                              │
│ ┌─ scotty ─────────────┐  ┌─ interactive ─────────────────┐ │
│ │ ⚠️ Stuck    · 8m15s  │  │ ⏳ Waiting   · 0m22s          │ │
│ │ Archon-CAD            │  │ HomeschoolHQ                  │ │
│ │ Build system migration│  │ (permission prompt)           │ │
│ │ ◆ build.rs            │  │                               │ │
│ │ ░░░░░▓▓▓▓▓▓▓▓▓▓ 95%  │  │ ░░░░░░░░░░░░░░░░ 12%         │ │
│ │ 180K tokens · 7 errors│  │ 8K tokens · 0 errors          │ │
│ └───────────────────────┘  └──────────────────────────────-┘ │
└──────────────────────────────────────────────────────────────┘
```

## Visual Design

- LazyVGrid with adaptive columns (minimum 260pt, maximum 340pt)
- Each card is an `AgentStatusCard` (TASK-137)
- Status colors: thinking=blue, writing=green, tool_use=cyan, waiting=orange, stuck=red, idle=gray
- Pulsing dot animation for active statuses (reuse LiveStreamsSection pattern)
- Context bar: horizontal progress bar showing context_used/context_max
- Cards are clickable — tap to navigate to session (if interactive) or inspect output (if dispatch)

## Section Behavior

- Shows when `AgentStatusStore.shared.activeSessions` is non-empty
- Falls back to existing LiveStreamsSection + ActiveWorkSection when agent_sessions table is empty (migration hasn't been populated yet by cortana-core)
- Section header: "AGENTS" with count badge, similar to existing "ACTIVE WORK" pattern
- Collapse/expand toggle (matching StarfleetActivitySection pattern)

## Acceptance Criteria

- [ ] Board renders with 0, 1, 2, 4, and 8 agents without layout issues
- [ ] Status colors match spec for all 9 status values
- [ ] Context progress bar fills proportionally
- [ ] Cards show agent name, project, task, current file, tokens, errors, duration
- [ ] Graceful fallback when agent_sessions table is empty
- [ ] VoiceOver accessible — each card reads as a coherent summary
