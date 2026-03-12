# TASK-145: Token & Cost Dashboard — Data Layer

**Priority**: high
**Status**: Todo
**Category**: architecture
**Epic**: Agent Orchestration Dashboard
**Sprint**: 2
**Agent**: geordi
**Complexity**: M
**Dependencies**: TASK-134

## Description

Aggregate token usage data for the dashboard. Extends existing `TokenStore` with burn rate calculations, time-windowed aggregations, and project-level summaries.

## Files to Modify

- **Modify**: `Sources/Core/Database/TokenStore.swift` — Add new query methods

## New Query Methods

```swift
extension TokenStore {
    /// Burn rate: tokens per minute over the last N minutes, grouped by session
    func burnRates(windowMinutes: Int = 30) -> [SessionBurnRate]

    /// Daily totals for the last N days
    func dailyTotals(days: Int = 7) -> [DailyTokenTotal]

    /// Per-project totals with activity window
    func projectSummaries() -> [ProjectTokenSummary]

    /// Context window usage per active session
    func contextUsage() -> [SessionContextUsage]
}

struct SessionBurnRate {
    let sessionId: String
    let project: String?
    let tokensPerMinute: Double
    let totalTokens: Int
    let windowStart: Date
}

struct DailyTokenTotal {
    let date: Date       // day boundary
    let inputTokens: Int
    let outputTokens: Int
    let model: String?
}

struct ProjectTokenSummary {
    let project: String
    let totalIn: Int
    let totalOut: Int
    let activeSessions: Int
    let lastActivityAt: Date?
}

struct SessionContextUsage {
    let sessionId: String
    let project: String?
    let estimatedUsed: Int
    let maxContext: Int
    let percentUsed: Double
}
```

## Burn Rate Calculation

```sql
SELECT
    tu.session_id,
    ss.project,
    SUM(tu.input_tokens + tu.output_tokens) as total_tokens,
    (julianday('now') - julianday(MIN(tu.recorded_at))) * 24 * 60 as minutes_elapsed,
    CASE
        WHEN (julianday('now') - julianday(MIN(tu.recorded_at))) * 24 * 60 > 0
        THEN SUM(tu.input_tokens + tu.output_tokens) / ((julianday('now') - julianday(MIN(tu.recorded_at))) * 24 * 60)
        ELSE 0
    END as tokens_per_minute
FROM canvas_token_usage tu
LEFT JOIN session_state ss ON ss.session_id = tu.session_id
WHERE tu.recorded_at > datetime('now', '-30 minutes')
GROUP BY tu.session_id
```

## Acceptance Criteria

- [ ] Burn rate returns correct tokens/minute for active sessions
- [ ] Daily totals aggregate correctly across sessions
- [ ] Project summaries match existing canvas_project_metrics data
- [ ] Context usage estimates are reasonable (not wildly over/under)
- [ ] All queries use table existence guards (shared DB pattern)
- [ ] Performance: all queries complete in <100ms on typical data
