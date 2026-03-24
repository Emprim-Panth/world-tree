# TASK-17: Audit and trim CommandCenter (remove deleted section references)

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 2 — Build Stabilize
**Depends on:** TASK-16

## Context

CommandCenterView.swift and CommandCenterViewModel.swift still reference the 17 sections deleted in TASK-11. This task cleans them up so the CommandCenter renders correctly with only the 5 kept sections.

## Sections to Keep

1. **Project Grid** — 2-column grid of `CompassProjectCard` (one per project from compass.db)
2. **Dispatch Activity** — Chronological list using `DispatchActivityView` (canvas_dispatches)
3. **Manual Dispatch** — `DispatchSheet` trigger button

## CommandCenterView — Required Structure

```swift
var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            // Project Grid
            ProjectGridSection()

            // Dispatch Activity
            DispatchActivitySection()
        }
        .padding()
    }
    .toolbar {
        ToolbarItem(placement: .primaryAction) {
            Button("Dispatch") { showingDispatchSheet = true }
        }
    }
    .sheet(isPresented: $showingDispatchSheet) {
        DispatchSheet()
    }
}
```

## CommandCenterViewModel — Required State

```swift
@Observable
final class CommandCenterViewModel {
    var projects: [CompassProject] = []
    var recentDispatches: [Dispatch] = []
    var isLoading: Bool = false

    func load() async { ... }   // reads compass.db + canvas_dispatches
    func refresh() async { ... }
}
```

Strip all other properties (agent status, sessions, factory floor, NERVE, tokens, Pencil, coordinator, etc.)

## Acceptance Criteria

- [ ] Read CommandCenterView.swift and CommandCenterViewModel.swift before editing
- [ ] CommandCenterView.swift renders only: project grid + dispatch activity + dispatch button
- [ ] CommandCenterViewModel.swift loads only: compass projects + recent dispatches
- [ ] No references to deleted types (AgentStatus, Factory, NERVE, Token, Pencil, etc.)
- [ ] App launches and CommandCenter displays project cards

## Notes

CompassProjectCard.swift, DispatchActivityView.swift, and DispatchSheet.swift are already kept from Phase 1. They may themselves have references to deleted types — read each one before deciding if they need trimming too.
