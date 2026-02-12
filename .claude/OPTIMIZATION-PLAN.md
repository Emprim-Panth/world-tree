# Canvas Optimization Master Plan

> Created: 2026-02-12
> Status: In Progress
> Goal: Transform Canvas from conversation app into the perfect command interface

## Wave 1 — Critical Fixes (Ship-Blocking)

### 1.1 Fix ClaudeCodeProvider Data Races
- `isRunning` and `currentProcess` accessed from multiple threads without synchronization
- **Fix:** Make `ClaudeCodeProvider` `@MainActor` or protect mutable state with locks
- **Files:** `Sources/Core/Providers/ClaudeCodeProvider.swift`

### 1.2 Throttle streamingResponse Updates
- Every text delta triggers `@Published` update → full SwiftUI re-render
- **Fix:** Debounce updates to 50ms intervals using a timer
- **Files:** `Sources/Features/Canvas/BranchViewModel.swift`

### 1.3 Async Process Execution (Remove MainActor Blocking)
- `Process.waitUntilExit()` blocks MainActor in multiple places
- **Fix:** Use `withCheckedContinuation` + `terminationHandler` pattern
- **Files:**
  - `ConversationStateManager.swift` — git branch check, cortana-context-restore
  - `AnthropicAPIProvider.swift` — KB query
  - `ProviderManager.swift` — launchctl API key resolution
  - `ToolExecutor.swift` — bash command execution

### 1.4 Fix O(n²) String Accumulation
- `accumulated += chunk` copies entire string on every delta
- **Fix:** Use array of chunks, join only at final save
- **Files:** `Sources/Features/Canvas/BranchViewModel.swift`

### 1.5 Fix Tool Name Collision in CLIStreamParser
- `activeToolNames: Set<String>` drops duplicate tool names (e.g., two `read_file` calls)
- **Fix:** Track by tool_use_id or (name, index) pairs
- **Files:** `Sources/Core/Providers/CLIStreamParser.swift`

## Wave 2 — Observability Layer

### 2.1 CanvasEvent Taxonomy
- Define event types: toolUse, textDelta, error, fork, completion, sessionStart, sessionEnd
- Store in SQLite `canvas_events` table
- **New file:** `Sources/Core/Events/CanvasEvent.swift`

### 2.2 Activity Pulse per Branch
- Colored indicator in tree sidebar showing recent activity density
- Based on event count in last N minutes
- **Files:** `Sources/Features/Sidebar/` views

### 2.3 Context Window Gauge
- Visual indicator per branch showing context usage %
- Yellow at 60%, red at 85%
- Track via CLIStreamParser result events or ConversationStateManager token estimates
- **New file:** `Sources/Shared/Components/ContextGauge.swift`

### 2.4 Auto-Generated Branch Summaries
- Use model to create 1-line summaries stored as branch metadata
- Display as tooltip/subtitle in tree view
- **Files:** TreeStore, BranchNode views

### 2.5 Tool Execution Timeline
- Expandable timeline showing all tool calls with durations
- Per-branch, stored in canvas_events
- **New file:** `Sources/Features/Canvas/ToolTimeline.swift`

## Wave 3 — Multi-Pane Interface

### 3.1 Split View (Side-by-Side Branches)
- HSplitView with two BranchViews for comparison
- Drag-to-split or button toggle
- **Files:** `Sources/Features/Canvas/CanvasView.swift`

### 3.2 Live Terminal Pane
- Embedded terminal showing running tool output in real time
- Connected to background jobs from JobQueue
- **New file:** `Sources/Features/Terminal/TerminalView.swift`

### 3.3 File Diff Pane
- Inline diff visualization for edit_file operations
- Already have DiffView component, need to make it first-class
- **Files:** `Sources/Features/Canvas/BranchView.swift`

### 3.4 Markdown Rendering
- Rich text in conversation messages (code blocks, headings, links, syntax highlighting)
- **New file:** `Sources/Shared/Components/MarkdownView.swift`

### 3.5 Process Monitor
- Mini Activity Monitor showing active processes and background jobs
- **New file:** `Sources/Features/Monitor/ProcessMonitor.swift`

## Wave 4 — Crew Visualization & Governance

### 4.1 Agent Swim Lanes
- Visual lanes per crew member showing activity
- Canvas-based chart (SwiftUI Canvas or Charts framework)
- **New file:** `Sources/Features/Agents/SwimLaneView.swift`

### 4.2 HITL Governance (Human-in-the-Loop)
- Native approval sheets for destructive operations
- Pre-flight check before rm, write_file to protected paths, etc.
- **Files:** `Sources/Core/Claude/ToolExecutor.swift`, new governance layer

### 4.3 Crew Delegation Chain
- Visual indicator of which crew member is active on which branch
- Branch metadata: `active_agent` field
- **Files:** TreeStore, BranchHeaderView

### 4.4 Pre-flight Security Gates
- Intercept dangerous commands before execution
- Pattern matching on tool inputs (rm -rf, force push, etc.)
- **New file:** `Sources/Core/Security/ToolGuard.swift`

## Wave 5 — Isolation & Sandboxing

### 5.1 Virtualization.framework Integration
- Local VMs per branch for true isolation
- Apple-native, no cloud dependency
- **New directory:** `Sources/Core/Sandbox/`

### 5.2 sandbox-exec Profiles
- Lightweight macOS sandboxing for filesystem/network restrictions
- Per-branch sandbox profiles
- **New file:** `Sources/Core/Sandbox/SandboxProfile.swift`

### 5.3 Workflow Templates
- Pre-built conversation structures for common dev tasks
- Template picker in new branch creation
- **New directory:** `Sources/Features/Templates/`

## DB Quick Wins (Apply During Wave 1)
- Add `PRAGMA wal_autocheckpoint = 1000`
- Verify/add `messages(session_id)` index
- Replace `branchPath()` with recursive CTE
- Cache message counts in `canvas_trees`
- Batch `updateBranch()` into single UPDATE

## Key Architecture Decisions
- All events stored in SQLite (local-first, privacy-first)
- No cloud dependencies (Buy Once, Own Forever)
- SwiftUI Canvas for visualizations (Charts for simple, Canvas for custom)
- Protocol-based execution layer (LocalExecutor → SandboxExecutor future)
- Event-driven architecture matching hooks repo pattern
