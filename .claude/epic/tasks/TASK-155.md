# TASK-155: Sprint 2 & 3 Integration + Polish

**Priority**: medium
**Status**: Done
**Category**: integration
**Epic**: Agent Orchestration Dashboard
**Sprint**: 3
**Agent**: geordi
**Complexity**: M
**Dependencies**: TASK-143, TASK-146, TASK-148, TASK-150, TASK-152, TASK-153, TASK-154

## Description

Final integration pass: wire all Sprint 2 and 3 components into the Command Center. Ensure all sections flow together visually, handle edge cases, and degrade gracefully.

## Files to Modify

- **Modify**: `Sources/Features/CommandCenter/CommandCenterView.swift`
  - Final layout order: header → AttentionPanel → AgentStatusBoard → TokenDashboard → projectGrid → StarfleetActivity → Pencil → RecentCompletions
  - Add EventRules button to header
  - Wire UIStateStore for section expand/collapse state
  - Connect ConflictDetector to DispatchSupervisor heartbeat

- **Modify**: `Sources/Core/Providers/DispatchSupervisor.swift`
  - Add ConflictDetector.check() to heartbeat timer
  - Add EventRuleStore.evaluate() to heartbeat timer

## Command Center Section Order (final)

```
1. Header (existing + attention badge + event rules button)
2. AttentionPanel (Sprint 1) — only when events exist
3. AgentStatusBoard (Sprint 1) — only when sessions exist
4. TokenDashboardView (Sprint 2) — collapsible
5. projectGrid (existing)
6. StarfleetActivitySection (existing)
7. PencilDesignSection (existing)
8. RecentCompletions (existing)
```

## Performance Check

- Ensure total DB queries per refresh cycle < 200ms
- Profile with Instruments for main thread stalls
- Verify no retain cycles between stores

## Acceptance Criteria

- [ ] All sections render in correct order
- [ ] Collapsible sections remember state across app restarts
- [ ] ConflictDetector runs every 30s without performance impact
- [ ] EventRuleStore evaluates rules every 30s
- [ ] No main thread stalls > 16ms from new code
- [ ] App launches without crash on fresh install (no existing tables)
- [ ] App launches without crash on existing install (tables exist with data)
