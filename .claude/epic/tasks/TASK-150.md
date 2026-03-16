# TASK-150: Event-Triggered Agent Launches — Rule Engine

**Priority**: medium
**Status**: Done
**Category**: architecture
**Epic**: Agent Orchestration Dashboard
**Sprint**: 3
**Agent**: geordi
**Complexity**: L
**Dependencies**: TASK-134, TASK-139

## Description

Rules engine that maps heartbeat signals and session events to automatic agent dispatches. "When build fails, dispatch Geordi" style automation.

## Files to Create

- **Create**: `Sources/Core/Models/EventRule.swift` — GRDB model for event_trigger_rules
- **Create**: `Sources/Core/Database/EventRuleStore.swift` — CRUD + matching engine

## EventRule Model

```swift
struct EventRule: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "event_trigger_rules"

    var id: String
    var name: String
    var enabled: Bool
    var triggerType: TriggerType
    var triggerConfig: TriggerConfig  // JSON-encoded
    var actionType: ActionType
    var actionConfig: ActionConfig    // JSON-encoded
    var lastTriggeredAt: Date?
    var triggerCount: Int
    let createdAt: Date

    enum TriggerType: String, Codable {
        case heartbeatSignal = "heartbeat_signal"  // governance_journal category
        case errorCount = "error_count"             // consecutive errors threshold
        case buildFailure = "build_failure"         // build job fails
        case sessionComplete = "session_complete"   // any session completes
    }

    enum ActionType: String, Codable {
        case dispatchAgent = "dispatch_agent"
        case notify = "notify"        // create attention event
        case runCommand = "run_command"
    }
}
```

## Matching Engine

```swift
@MainActor
final class EventRuleStore: ObservableObject {
    static let shared = EventRuleStore()

    @Published private(set) var rules: [EventRule] = []

    func loadRules()
    func createRule(_ rule: EventRule)
    func updateRule(_ rule: EventRule)
    func deleteRule(_ id: String)

    /// Evaluate all enabled rules against current events.
    /// Called by DispatchSupervisor heartbeat (every 30s).
    func evaluate(
        signals: [HeartbeatSignal],
        sessions: [AgentSession],
        attentionEvents: [AttentionEvent]
    ) async -> [TriggeredAction]
}

struct TriggeredAction {
    let rule: EventRule
    let action: EventRule.ActionType
    let config: ActionConfig
}
```

## Safety Guards

- **Cooldown**: Each rule has minimum 30 minutes between triggers (check lastTriggeredAt)
- **Global cap**: Maximum 3 auto-dispatches per hour across all rules
- **Daily cap**: Maximum 15 auto-dispatches per day
- **Confirmation mode**: Optional flag `requireConfirmation` that creates an attention event instead of auto-dispatching

## Built-in Rule Templates

Pre-populate with sensible defaults (user can edit/disable):
1. "Build failure auto-fix" — heartbeat_signal="build_staleness" → dispatch geordi
2. "Error loop intervention" — error_count >= 5 → dispatch worf (debugging specialist)
3. "Stale ticket nudge" — heartbeat_signal="stale_ticket" → notify

## Dispatch Integration

When a rule triggers `dispatchAgent`:
- Use existing `ClaudeBridge.shared.dispatch()` path
- Set origin="event_rule" on the dispatch
- Agent name from actionConfig
- Project from triggerConfig or the event's project
- Prompt from actionConfig.prompt_template with variable substitution ({project}, {error}, {signal})

## Acceptance Criteria

- [ ] Rules persist across app restarts (SQLite)
- [ ] Matching correctly evaluates trigger conditions
- [ ] Cooldown prevents rapid re-triggering
- [ ] Global hourly cap enforced
- [ ] Dispatch uses existing ClaudeBridge path
- [ ] Template rules created on first launch
- [ ] Disabled rules are skipped during evaluation
