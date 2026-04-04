# TASK-134: WorldTree — Crew Registry panel

**Status:** open
**Priority:** medium
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 5 — WorldTree UI
**Agent:** Data
**Depends on:** TASK-117, TASK-120
**Blocks:** nothing

## What

A read-only panel in WorldTree showing the full crew roster from crew_registry. Both departments visible. Shows tier, role, namespace access, active status, and last session timestamp. Evan can toggle active/inactive. No agent can see or modify this view.

## UI Layout

```
┌─ Crew Registry ─────────────────────────────────────────────┐
│ [Coding Dept]  [Game Dev Dept]                               │
├─────────────────────────────────────────────────────────────┤
│ 🟢 Cortana   · CTO (Tier 1)   · sonnet/opus · Last: 4m ago  │
│    Writes: all namespaces                                    │
├─────────────────────────────────────────────────────────────┤
│ 🟢 Picard    · Dept Head (T2) · sonnet      · Last: 2h ago  │
│    Writes: all namespaces                                    │
├─────────────────────────────────────────────────────────────┤
│ 🟢 Geordi    · Architect (T3) · sonnet      · Last: 1d ago  │
│    Writes: assigned-project, project-development, game-dev  │
│                                                   [Deactivate] │
└─────────────────────────────────────────────────────────────┘
```

## Tabs

- **Coding Dept**: all crew relevant to coding work (Picard, Spock, Geordi, Data, Worf, Torres, Dax, Scotty, Uhura, Troi, Seven, Bashir, Garak, Q, Kim, Quark, O'Brien, Paris, Nog, Sato, Odo, Zimmerman)
- **Game Dev Dept**: crew with game dev roles (Picard, Spock, Geordi, Data, Uhura, Worf, Quark, Composer, Torres, Scotty, Troi, Paris, Scotty, Nog, Sato)

## Data Source

`GET /crew` → all crew_registry rows

## Acceptance Criteria

- [ ] Both department tabs visible
- [ ] Tier badge (T1/T2/T3/T4) and model shown per crew member
- [ ] Namespace write access listed concisely
- [ ] Last session time pulled from agent_sessions table
- [ ] Active/inactive toggle: PATCH /crew/{name}/active → updates crew_registry.active
- [ ] Inactive crew shown greyed out, cannot be spawned
- [ ] Read-only for all agent sessions (only Evan via WorldTree can toggle)
- [ ] Uses Palette.* for all colors

## Files

- `Sources/Features/CrewRegistry/CrewRegistryView.swift`
- `Sources/Features/CrewRegistry/CrewRegistryViewModel.swift`
- `Sources/Core/ContextServer/ContextServer.swift` — add GET /crew, PATCH /crew/{name}/active
