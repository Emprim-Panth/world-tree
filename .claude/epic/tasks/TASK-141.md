# TASK-141: Diff Review — Git Diff Display Component

**Priority**: high
**Status**: Todo
**Category**: ui
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: data
**Complexity**: XL
**Dependencies**: TASK-134

## Description

PR-style diff view for reviewing agent output. When an agent completes work, show what files changed with additions/deletions, syntax-colored. The core value prop: review agent work without leaving World Tree.

## Files to Create

- **Create**: `Sources/Features/CommandCenter/DiffReviewView.swift` — Inline diff component for Command Center
- **Create**: `Sources/Features/CommandCenter/DiffReviewSheet.swift` — Full-screen diff sheet with file list
- **Create**: `Sources/Core/Database/DiffReviewStore.swift` — Background git diff execution + caching

## DiffReviewStore

```swift
actor DiffReviewStore {
    static let shared = DiffReviewStore()

    struct DiffResult: Sendable {
        let sessionId: String
        let files: [FileDiff]
        let totalAdditions: Int
        let totalDeletions: Int
        let generatedAt: Date
    }

    struct FileDiff: Identifiable, Sendable {
        let id: String  // file path
        let path: String
        let status: FileStatus  // added, modified, deleted, renamed
        let additions: Int
        let deletions: Int
        let hunks: [DiffHunk]
    }

    struct DiffHunk: Identifiable, Sendable {
        let id: Int
        let header: String  // @@ -10,5 +10,8 @@
        let lines: [DiffLine]
    }

    struct DiffLine: Identifiable, Sendable {
        let id: Int
        let type: LineType  // context, addition, deletion
        let content: String
        let oldLineNumber: Int?
        let newLineNumber: Int?
    }

    func generateDiff(for sessionId: String) async -> DiffResult?
}
```

## Git Diff Strategy

1. Look up `agent_sessions.working_directory` for the session
2. Run `git diff HEAD~1` in that directory (background Process, 10s timeout)
3. For dispatch sessions that used worktrees: diff against the base branch
4. Parse unified diff output into structured `FileDiff` objects
5. Cache result in memory (dictionary keyed by sessionId, evict after 20 entries)

## Diff View Layout

```
┌─ Diff Review: geordi on WorldTree ──── 3 files · +45 -12 ── [Approve] ─┐
│                                                                           │
│ ▸ Sources/Core/Database/AgentStatusStore.swift  (+30 -2)                 │
│ ▸ Sources/Core/Models/AgentSession.swift        (+12 -0)     [new file]  │
│ ▸ Sources/Core/Database/MigrationManager.swift  (+3 -10)                 │
│                                                                           │
│ ── Sources/Core/Database/AgentStatusStore.swift ──────────────────────── │
│  10  │    @Published private(set) var activeSessions: [AgentSession] = []│
│  11 +│    @Published private(set) var stuckSessions: [AgentSession] = [] │
│  12 +│    @Published private(set) var contextWarnings: [AgentSession] = []│
│  13  │                                                                    │
│  14  │    func refreshAsync() async {                                     │
│  15 -│        // old implementation                                       │
│  16 +│        let result = try await Self.fetchAllAsync()                 │
│  17 +│        self.activeSessions = result.active                         │
└───────────────────────────────────────────────────────────────────────────┘
```

## Syntax Coloring

- Additions: green background tint
- Deletions: red background tint
- Context: no tint
- Line numbers: monospaced, dimmed
- File headers: bold, with status badge (new/modified/deleted)

## Approve Action

"Approve" button acknowledges the review_ready attention event. It does NOT perform any git operations — purely a UI acknowledgment.

## Acceptance Criteria

- [ ] Git diff runs on background thread, never blocks UI
- [ ] Diff parses correctly for added, modified, deleted, and renamed files
- [ ] Unified diff hunks display with correct line numbers
- [ ] Addition/deletion line coloring is visually clear
- [ ] File list is collapsible (expand/collapse individual files)
- [ ] Full-screen sheet available for complex diffs
- [ ] 10-second timeout on git operations
- [ ] Handles repos with no changes gracefully
- [ ] Handles non-git directories gracefully (shows "not a git repository")
