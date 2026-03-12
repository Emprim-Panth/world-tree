# TASK-142: Sprint 1 Integration — Wire Everything Together

**Priority**: high
**Status**: Done
**Category**: integration
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: geordi
**Complexity**: M
**Dependencies**: TASK-135, TASK-136, TASK-139, TASK-140, TASK-141

## Description

Integration task: wire all Sprint 1 components into the Command Center. Update CommandCenterView to show the new sections, connect stores to the observation lifecycle, and verify end-to-end data flow.

## Files to Modify

- **Modify**: `Sources/Features/CommandCenter/CommandCenterView.swift`
  - Add `@ObservedObject private var agentStore = AgentStatusStore.shared`
  - Add `@ObservedObject private var attentionStore = AttentionStore.shared`
  - Insert `AttentionPanel()` after header
  - Insert `AgentStatusBoard()` after AttentionPanel, before projectGrid
  - Keep existing `LiveStreamsSection()` and `ActiveWorkSection(...)` as fallback when agentStore.activeSessions is empty
  - Start/stop agent store observation in onAppear/onDisappear

- **Modify**: `Sources/Features/CommandCenter/CommandCenterViewModel.swift`
  - Remove activeDispatches/activeJobs from observation IF agent_sessions table exists (avoid duplicate display)
  - Keep as fallback when table doesn't exist

- **Modify**: `Sources/App/AppState.swift` or equivalent startup path
  - Call `AgentStatusStore.shared.startObserving()` at app launch
  - Call `AttentionStore.shared.startObserving()` at app launch

## Graceful Degradation

The new views must coexist with the old ones during transition:
1. If `agent_sessions` table exists AND has data → show new AgentStatusBoard, hide old LiveStreamsSection/ActiveWorkSection
2. If table exists but empty → show old sections (cortana-core hasn't been updated yet)
3. If table doesn't exist → show old sections (migration hasn't run on this DB)

## End-to-End Verification

Manual test flow:
1. Launch World Tree → Command Center shows
2. Dispatch an agent from the Dispatch button
3. agent_sessions row appears (from cortana-core hooks)
4. AgentStatusBoard shows the running agent card
5. Agent completes → card moves to completed
6. Attention event appears → AttentionPanel shows
7. Click "Review" → DiffReviewSheet opens with git diff
8. Dismiss → event acknowledged

## Acceptance Criteria

- [ ] Command Center renders without crash on fresh launch
- [ ] New sections visible when agent_sessions has data
- [ ] Old sections visible when agent_sessions is empty
- [ ] No duplicate display of the same dispatch in both old and new sections
- [ ] Stores start observing on app launch and stop on view disappear
- [ ] Memory: no retain cycles between stores and views
