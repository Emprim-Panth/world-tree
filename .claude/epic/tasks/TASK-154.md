# TASK-154: Persistent UI State

**Priority**: low
**Status**: Done
**Category**: feature
**Epic**: Agent Orchestration Dashboard
**Sprint**: 3
**Agent**: scotty
**Complexity**: S
**Dependencies**: TASK-134

## Description

Save and restore Command Center UI state across app restarts: which sections are expanded, filter selections, watched sessions, and layout preferences.

## Files to Create

- **Create**: `Sources/Core/Database/UIStateStore.swift`

## Implementation

```swift
@MainActor
final class UIStateStore {
    static let shared = UIStateStore()

    func set(_ key: String, value: String)
    func get(_ key: String) -> String?
    func getBool(_ key: String) -> Bool?
    func remove(_ key: String)
}
```

Uses the `ui_state` table (created in TASK-134 migration).

## State Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cc.section.agents.expanded` | Bool | true | Agent Status Board expanded |
| `cc.section.tokens.expanded` | Bool | false | Token Dashboard expanded |
| `cc.section.crew.expanded` | Bool | true | Starfleet Activity expanded |
| `cc.section.recent.expanded` | Bool | true | Recent Completions expanded |
| `cc.filter.project` | String? | nil | Active project filter |
| `cc.filter.agent` | String? | nil | Active agent filter |
| `cc.watched.sessions` | JSON | [] | Session IDs user is watching |
| `cc.layout.columns` | Int | 2 | Grid column count preference |

## Integration Points

- Each collapsible section reads initial state from UIStateStore on appear
- Each toggle writes back to UIStateStore
- CommandCenterViewModel reads project/agent filters on startup

## Migration from UserDefaults

Currently `UserDefaults.standard.bool(forKey: "pencil.feature.enabled")` is used for Pencil toggle. Don't migrate this — leave Pencil in UserDefaults. UIStateStore is only for Command Center layout state.

## Acceptance Criteria

- [ ] Expanded/collapsed state survives app restart
- [ ] Filter selections persist
- [ ] Watched sessions list persists
- [ ] Writing state doesn't block UI (async or fire-and-forget)
- [ ] Missing keys return sensible defaults
- [ ] No data loss if table doesn't exist yet (graceful fallback to defaults)
