# TASK-159: HIGH — Context + Memory Provenance Surface

**Priority**: high
**Status**: Pending
**Category**: knowledge
**Epic**: Audit Follow-Up
**Sprint**: 4
**Agent**: spock
**Complexity**: L
**Dependencies**: TASK-153

## Description

World Tree injects a rich stack of context on every send: recent conversation, scored context, rotation checkpoints, project context, gameplans, and cross-session memory from `MemoryService`. The operator currently sees almost none of that reasoning in a usable place.

`ContextInspectorView` exists, but it is not wired into the active conversation flow. `SessionMemoryView` only appears off the Command Center agent card. The result is hidden intelligence: powerful under the hood, low trust at the glass.

Build a provenance surface that shows exactly what was injected, why it was selected, how much token budget it consumed, and what timed out or was omitted.

## Files to Modify

- **Modify**: `Sources/Features/Context/ContextInspectorView.swift`
- **Modify**: `Sources/Features/Document/DocumentEditorView.swift`
- **Modify**: `Sources/Core/Context/SendContextBuilder.swift`
- **Modify**: `Sources/Core/Context/MemoryService.swift`
- **Create**: `Tests/ContextBuilderTests/ContextProvenanceTests.swift`

## Requirements

- Wire `ContextInspectorView` into the live conversation UI
- Expose the exact send components for the most recent turn:
  - gameplan
  - recent conversation block
  - checkpoint block
  - scored context
  - memory recall hits
  - project context
- Show reason metadata where possible: source, rank, token estimate, timeout, omitted state
- Surface when memory recall timed out or returned nothing so silence is explainable

## Acceptance Criteria

- [ ] A user can inspect the last send context from the conversation UI without opening Command Center
- [ ] Memory recall shows source categories and why each snippet was included
- [ ] Context blocks show token estimates and pinned/protected status
- [ ] Timeouts and empty recall states are explicitly visible, not silent
- [ ] Tests verify provenance payload structure and no regressions in existing context assembly
