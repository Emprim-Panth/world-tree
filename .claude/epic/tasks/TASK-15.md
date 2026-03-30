# TASK-15: Trim AppState to command center scope

**Status:** done
**Priority:** high
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 2 — Build Stabilize
**Depends on:** TASK-14

## Context

AppState.swift is the global @Observable state object. It currently contains state for: active branches, conversations, streaming, provider selection, agent dispatch, daemon connection, Pencil, terminal sessions, and more. After Phase 1 deletions, most of its properties reference deleted types. Trim it to only what CommandCenter, Tickets, and Brain need.

## Required Interface (post-trim)

```swift
@Observable
final class AppState {
    // Navigation
    var selectedProject: String?
    var selectedTicketId: String?
    var navigationPanel: NavigationPanel = .commandCenter

    // System status (read-only, polled)
    var gatewayReachable: Bool = false
    var contextServerReachable: Bool = false
    var lastHeartbeatAt: Date?

    // No conversation state. No branch state. No streaming state.
    // No provider state. No daemon state.
}

enum NavigationPanel {
    case commandCenter
    case tickets
    case brain
    case settings
}
```

## Acceptance Criteria

- [ ] AppState.swift read first, then trimmed (not rewritten from scratch if avoidable)
- [ ] No references to deleted types remain in AppState.swift
- [ ] AppState compiles cleanly in isolation
- [ ] No properties for: branches, conversations, messages, streaming, providers, daemon, Pencil, jobs, agents, tokens

## Notes

Read AppState.swift before editing. Trim is preferred over rewrite — preserve any non-chat state that makes sense (window management, launch state, etc.).
