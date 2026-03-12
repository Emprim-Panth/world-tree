# TASK-139: Attention Router — Priority Notification System

**Priority**: critical
**Status**: Todo
**Category**: architecture
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: geordi
**Complexity**: M
**Dependencies**: TASK-134, TASK-138

## Description

Build `AttentionStore` — a reactive store that surfaces the most important items requiring Evan's attention, ranked by severity. This is the "never miss a stuck agent" guarantee.

## Files to Create

- **Create**: `Sources/Core/Database/AttentionStore.swift`

## Priority Ranking (highest to lowest)

1. **permission_needed** (critical) — Agent waiting for user input/approval
2. **error_loop** (critical) — Agent stuck in 3+ consecutive errors
3. **stuck** (warning) — Agent inactive for 5+ minutes but process alive
4. **context_low** (warning) — Agent at >85% context usage
5. **conflict** (warning) — Two agents touching same file
6. **review_ready** (info) — Dispatch completed, output ready for review
7. **completed** (info) — Session finished successfully

## Implementation

```swift
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    @Published private(set) var unacknowledged: [AttentionEvent] = []
    @Published private(set) var criticalCount: Int = 0
    @Published private(set) var warningCount: Int = 0

    func startObserving()   // ValueObservation on agent_attention_events WHERE acknowledged = 0
    func stopObserving()
    func acknowledge(_ id: String)  // SET acknowledged = 1, acknowledged_at = now
    func acknowledgeAll()
}
```

- ValueObservation on `agent_attention_events WHERE acknowledged = 0 ORDER BY severity priority, created_at DESC`
- Severity ordering: critical=0, warning=1, info=2 (use CASE WHEN in SQL)
- Limit to 50 unacknowledged events to prevent unbounded growth
- Auto-acknowledge 'completed' events older than 1 hour

## Badge Integration

Expose `criticalCount` and `warningCount` for the Command Center header to show a badge:
- Red badge if criticalCount > 0
- Orange badge if warningCount > 0 and criticalCount == 0

## Acceptance Criteria

- [ ] Events sorted by severity then recency
- [ ] Acknowledging an event removes it from the list
- [ ] Critical events produce red badge count
- [ ] Auto-acknowledges stale 'completed' events
- [ ] ValueObservation fires on INSERT into agent_attention_events
- [ ] Handles missing table gracefully (returns empty)
