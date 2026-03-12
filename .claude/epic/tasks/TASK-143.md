# TASK-143: Session Health Scoring — Red/Yellow/Green

**Priority**: high
**Status**: Todo
**Category**: architecture
**Epic**: Agent Orchestration Dashboard
**Sprint**: 2
**Agent**: geordi
**Complexity**: M
**Dependencies**: TASK-135

## Description

Calculate a composite health score per session that reduces to red/yellow/green. Combines token burn rate, error frequency, retry count, and file diversity into a single productivity signal.

## Files to Create

- **Create**: `Sources/Core/Models/SessionHealth.swift`

## Health Score Algorithm

```swift
struct SessionHealth {
    let score: Double          // 0.0 (critical) to 1.0 (healthy)
    let level: HealthLevel     // .red, .yellow, .green
    let factors: [HealthFactor]

    enum HealthLevel: String {
        case red, yellow, green
    }

    struct HealthFactor {
        let name: String       // "burn_rate", "error_rate", "retry_rate", "productivity"
        let value: Double      // 0.0 to 1.0
        let description: String
    }
}
```

### Scoring Factors (weighted)

1. **Error Rate** (weight: 0.35)
   - `error_score = 1.0 - min(consecutive_errors / 5.0, 1.0)`
   - 0 errors = 1.0, 5+ consecutive = 0.0

2. **Burn Rate** (weight: 0.25)
   - `burn_rate = tokens_out / elapsed_minutes`
   - Healthy: 500-3000 tokens/min → 1.0
   - Low (<100 tokens/min for >5 minutes) → 0.3 (agent may be stuck)
   - Very high (>5000 tokens/min) → 0.7 (may be in a loop)

3. **Context Pressure** (weight: 0.25)
   - `context_score = 1.0 - (context_used / context_max)`
   - >90% used → 0.1 (critical)
   - 70-90% → 0.5 (warning)
   - <70% → 1.0

4. **File Diversity** (weight: 0.15)
   - `file_score = min(unique_files_touched / 3.0, 1.0)`
   - If touching >0 files, agent is productive
   - 0 files after 10+ minutes → 0.2

### Composite Score

```
score = (error_score * 0.35) + (burn_rate_score * 0.25) + (context_score * 0.25) + (file_score * 0.15)
```

- Green: score >= 0.65
- Yellow: score >= 0.35
- Red: score < 0.35

### Static Overrides

- `consecutive_errors >= 5` → always red (regardless of other factors)
- `context_used / context_max > 0.95` → always red
- `status == 'stuck'` → always red

## Integration

- `AgentStatusStore` calls `SessionHealth.calculate(from: AgentSession)` on each refresh
- Published as `healthScores: [String: SessionHealth]` keyed by session ID
- `AgentStatusCard` (TASK-137) reads health score for badge rendering

## Acceptance Criteria

- [ ] Score correctly computes for all factor combinations
- [ ] Static overrides take precedence
- [ ] Green/yellow/red thresholds produce expected results for realistic scenarios
- [ ] Calculation is pure (no DB access) — takes AgentSession as input, returns SessionHealth
- [ ] Unit tests for edge cases: new session (0 tokens), stuck session, context-exhausted session
