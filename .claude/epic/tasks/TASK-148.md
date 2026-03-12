# TASK-148: Cross-Agent Conflict Detection

**Priority**: medium
**Status**: Done
**Category**: architecture
**Epic**: Agent Orchestration Dashboard
**Sprint**: 2
**Agent**: geordi
**Complexity**: M
**Dependencies**: TASK-147

## Description

Detect when two or more active agents are editing the same file and surface a warning before merge conflicts occur.

## Files to Create

- **Create**: `Sources/Core/Database/ConflictDetector.swift`

## Detection Algorithm

```swift
@MainActor
final class ConflictDetector: ObservableObject {
    static let shared = ConflictDetector()

    struct FileConflict: Identifiable {
        let id: String          // file_path
        let filePath: String
        let project: String
        let agents: [ConflictingAgent]
        let severity: ConflictSeverity
        let detectedAt: Date
    }

    struct ConflictingAgent {
        let sessionId: String
        let agentName: String?
        let lastTouchAt: Date
        let action: String  // edit, create, delete
    }

    enum ConflictSeverity {
        case active   // Both agents currently active and touching same file
        case recent   // One agent touched file in last 10 min, another is active
    }

    @Published private(set) var activeConflicts: [FileConflict] = []

    func check() async  // Run detection query
}
```

## SQL Query

```sql
SELECT
    ft1.file_path,
    ft1.project,
    ft1.session_id as session1,
    ft1.agent_name as agent1,
    ft1.touched_at as touch1,
    ft2.session_id as session2,
    ft2.agent_name as agent2,
    ft2.touched_at as touch2
FROM agent_file_touches ft1
JOIN agent_file_touches ft2
    ON ft1.file_path = ft2.file_path
    AND ft1.session_id != ft2.session_id
    AND ft1.action IN ('edit', 'create', 'delete')
    AND ft2.action IN ('edit', 'create', 'delete')
JOIN agent_sessions s1 ON s1.id = ft1.session_id
    AND s1.status NOT IN ('completed', 'failed', 'interrupted')
JOIN agent_sessions s2 ON s2.id = ft2.session_id
    AND s2.status NOT IN ('completed', 'failed', 'interrupted')
WHERE ft1.touched_at > datetime('now', '-10 minutes')
    AND ft2.touched_at > datetime('now', '-10 minutes')
ORDER BY ft1.touched_at DESC
```

## Attention Event Generation

When a conflict is detected:
```sql
INSERT INTO agent_attention_events (id, session_id, type, severity, message, metadata)
VALUES (?, ?, 'conflict', 'warning',
    'File conflict: {file_path} being edited by {agent1} and {agent2}',
    '{"file": "...", "agents": ["...", "..."]}')
```

Only create the event once per file+agent pair (check for existing unacknowledged conflict event).

## Integration

- `ConflictDetector.check()` called by DispatchSupervisor heartbeat (every 30s) — reuse existing timer
- Also called on demand when a new file touch is detected (debounced)

## Acceptance Criteria

- [ ] Detects when two active sessions edit the same file
- [ ] Does not false-positive on read-only access
- [ ] Creates attention event only once per conflict (no duplicates)
- [ ] Handles sessions in different projects editing files with same relative path (must be same absolute path)
- [ ] Query performance acceptable with 1000+ file touches (indexed)
- [ ] No conflict reported when one session is already completed
