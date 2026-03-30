# TASK-16: Rebuild ContentView (3-panel navigation)

**Status:** done
**Priority:** high
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 2 — Build Stabilize
**Depends on:** TASK-15

## Context

ContentView.swift currently renders the full chat interface: sidebar (branch tree), canvas (document editor), and inspector. This is deleted. Replace with a 3-panel command center layout: left nav rail, main content area, optional detail pane.

## Target Layout

```
┌─────────────────────────────────────────────────────────┐
│  World Tree                                             │
├──────────┬──────────────────────────────────────────────┤
│  Nav     │  Main Content                               │
│          │                                             │
│  [CC]    │  CommandCenter  /  Tickets  /  Brain        │
│  [TK]    │  (switches based on nav selection)          │
│  [BR]    │                                             │
│  [ST]    │                                             │
│          │                                             │
└──────────┴──────────────────────────────────────────────┘

Nav icons:
[CC] CommandCenter (house icon)
[TK] Tickets (list icon)
[BR] Brain (brain/book icon)
[ST] Settings (gear icon)
```

## Implementation

Use `NavigationSplitView` (macOS 14+). Sidebar is a simple icon + label list. Detail column shows the active panel's view.

```swift
NavigationSplitView {
    List(selection: $appState.navigationPanel) {
        Label("Command Center", systemImage: "house")
            .tag(NavigationPanel.commandCenter)
        Label("Tickets", systemImage: "checklist")
            .tag(NavigationPanel.tickets)
        Label("Brain", systemImage: "brain")
            .tag(NavigationPanel.brain)
        Divider()
        Label("Settings", systemImage: "gear")
            .tag(NavigationPanel.settings)
    }
    .listStyle(.sidebar)
} detail: {
    switch appState.navigationPanel {
    case .commandCenter: CommandCenterView()
    case .tickets: AllTicketsView()
    case .brain: BrainEditorView()       // built in TASK-19
    case .settings: SettingsView()
    }
}
```

## Acceptance Criteria

- [ ] ContentView.swift read before editing
- [ ] Layout matches the spec above (nav rail + main content)
- [ ] All 4 panels navigate correctly
- [ ] BrainEditorView can be stubbed as `Text("Brain — coming soon")` until TASK-19
- [ ] App builds and launches cleanly after this task
- [ ] No references to branches, canvas, conversations, or document views

## Notes

This is the first full build checkpoint. After TASK-16, `xcodebuild -scheme WorldTree` should succeed with no errors. TASK-17 is cleanup of CommandCenter internals, not a blocker for building.
