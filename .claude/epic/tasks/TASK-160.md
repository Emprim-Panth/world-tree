# TASK-160: HIGH — Inline Proposal Cards + Sign-Off Workflow

**Priority**: high
**Status**: Done
**Category**: ui
**Epic**: Audit Follow-Up
**Sprint**: 4
**Agent**: geordi
**Complexity**: L

## Description

World Tree has pieces of a sign-off system, but they are scattered:

- `CortanaControlView` previews prompt injection in Settings
- `DispatchSheet` previews model routing for background work
- `FileDiffSheet` asks for approval after a write is already proposed

What it does not have is the operator surface Evan actually asked for: an inline proposal card inside the conversation that says "here’s what I want to make, here’s the route, here are the likely files or surfaces, here’s the risk, approve or revise."

Build a single proposal/sign-off workflow for complex actions before execution starts.

## Files to Modify

- **Modify**: `Sources/Features/Document/DocumentEditorView.swift`
- **Modify**: `Sources/Shared/Components/ArtifactRendererView.swift`
- **Modify**: `Sources/Features/CommandCenter/DispatchSheet.swift`
- **Modify**: `Sources/Core/Providers/CortanaWorkflowPlanner.swift`
- **Modify**: `Sources/Core/Security/ApprovalCoordinator.swift`
- **Create**: `Sources/Core/Models/ProposedWorkArtifact.swift`

## Proposal Card Contents

- goal / user request summary
- planned steps
- primary model and optional reviewer
- likely file or project scope
- risk level
- whether work is read-only, design-only, or write-capable
- approve / revise / cancel controls

If a concept preview is available, the card should be able to attach it without requiring file edits.

## Acceptance Criteria

- [ ] Complex actions can produce a proposal artifact instead of immediately executing
- [ ] Proposal renders inline in the conversation, not buried in Settings
- [ ] User can approve, revise, or cancel from the proposal card
- [ ] Dispatch routing summary and reviewer plan are visible in the same artifact
- [ ] Existing file-diff approval remains intact and complements the higher-level proposal flow
