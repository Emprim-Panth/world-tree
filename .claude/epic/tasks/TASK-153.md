# TASK-153: Session Memory Visualization

**Priority**: low
**Status**: Done
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 3
**Agent**: data
**Complexity**: M
**Dependencies**: TASK-135, TASK-145

## Description

Visual representation of what context each agent session has: files in context, knowledge injected, what was lost to compaction, and how much context window remains.

## Files to Create

- **Create**: `Sources/Features/CommandCenter/SessionMemoryView.swift`

## Data Sources

1. **session_state.files_touched** — JSON array of file paths the session has accessed
2. **session_state.decisions_made** — JSON array of decisions in context
3. **session_state.user_directives** — JSON array of standing instructions
4. **canvas_token_usage** — Token history showing compaction events (gaps in token counts)
5. **agent_sessions.context_used/context_max** — Current context window fill

## Layout (shown in a popover or sheet from AgentStatusCard)

```
┌─ Session Memory: geordi on WorldTree ─────────────────────┐
│                                                             │
│  Context Window                                             │
│  ░░░░░░░░░░░░▓▓▓▓ 68%  (136K / 200K)                      │
│                                                             │
│  Files in Context (12)                                      │
│  ├── Sources/Core/Database/AgentStatusStore.swift            │
│  ├── Sources/Core/Models/AgentSession.swift                 │
│  ├── Sources/Core/Database/MigrationManager.swift           │
│  └── ... 9 more                                             │
│                                                             │
│  Knowledge Injected                                         │
│  • 3 corrections from knowledge base                        │
│  • 2 anti-patterns matched                                  │
│                                                             │
│  Decisions Made (2)                                         │
│  • "Use ValueObservation over polling"                      │
│  • "Follow HeartbeatStore pattern for new stores"           │
│                                                             │
│  Compaction Events: 0                                       │
│  Session Duration: 12m07s                                   │
│  Total Tokens: 145K (in: 120K, out: 25K)                   │
└─────────────────────────────────────────────────────────────┘
```

## Compaction Detection

A compaction event likely occurred when there's a significant drop in per-turn input tokens (the context shrank). Detect by looking for:
- Turn N: input_tokens = 150K
- Turn N+1: input_tokens = 50K
- Delta > 50K → likely compaction

## Acceptance Criteria

- [ ] Shows files in context from session_state
- [ ] Shows knowledge injections (count from session context)
- [ ] Shows decisions made
- [ ] Context bar with accurate fill percentage
- [ ] Compaction events detected from token history gaps
- [ ] Popover opens from AgentStatusCard secondary action
- [ ] Handles sessions with no session_state data gracefully
