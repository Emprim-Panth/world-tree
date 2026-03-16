# World Tree Architecture

**Current State**: Functional conversation UI with tool execution, Compass integration, and stream management
**Target State**: Unified development environment with full system awareness
**Architect**: Geordi & Data
**Mission**: See MISSION.md

---

## System Overview

### High-Level Architecture
```
┌─────────────────────────────────────────────────────────────┐
│ World Tree (SwiftUI macOS App)                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐    │
│  │  Conversation │   │   Project    │   │   Terminal   │    │
│  │     Layer     │   │ Intelligence │   │  Integration │    │
│  │              │   │    Layer     │   │    Layer     │    │
│  └──────────────┘   └──────────────┘   └──────────────┘    │
│         │                   │                   │           │
│         └───────────────────┴───────────────────┘           │
│                         │                                   │
│                    ┌────▼────┐                              │
│                    │ Claude  │                              │
│                    │ Bridge  │                              │
│                    └────┬────┘                              │
│                         │                                   │
├─────────────────────────┼───────────────────────────────────┤
│                         │                                   │
│  ┌──────────────────────▼────────────────────────┐         │
│  │      Cortana Daemon (Python)                  │         │
│  │  - Service Coordination                       │         │
│  │  - Background Jobs                            │         │
│  │  - Process Monitoring                         │         │
│  │  - File System Watching                       │         │
│  └───────────────────────────────────────────────┘         │
│                         │                                   │
├─────────────────────────┼───────────────────────────────────┤
│                         │                                   │
│  ┌──────────────────────▼────────────────────────┐         │
│  │  Shared Database (SQLite + WAL)               │         │
│  │  - Conversation History                       │         │
│  │  - Project Cache                              │         │
│  │  - Terminal Sessions                          │         │
│  │  - Background Jobs                            │         │
│  └────────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

---

## Module Structure

### Existing Modules

#### `Sources/Core/Database/`
**Responsibility**: Data persistence layer  
**Components**:
- `DatabaseManager` — Connection pool with WAL mode
- `TreeStore` — CRUD for conversation trees/branches
- `MessageStore` — Message history queries
- `MigrationManager` — Schema evolution

**Stability**: High (foundational)  
**Dependencies**: GRDB

#### `Sources/Core/Claude/`
**Responsibility**: Claude API communication and tool execution  
**Components**:
- `ClaudeBridge` — Orchestration (API or CLI fallback)
- `AnthropicClient` — Direct API HTTP client with SSE
- `ConversationStateManager` — Context windowing, prompt caching
- `ToolExecutor` — Local tool implementation (actor for thread safety)
- `ToolDefinitions` — JSON Schema for tools

**Stability**: Medium (stable interface, evolving internals)  
**Dependencies**: Foundation, URLSession

#### `Sources/Core/Daemon/`
**Responsibility**: Integration with cortana-daemon  
**Components**:
- `DaemonSocket` — Unix socket communication
- `DaemonService` — Service status queries
- `LogTailer` — Stream daemon logs

**Stability**: Medium (interface stable, adding features)  
**Dependencies**: Foundation

#### `Sources/Features/Document/`
**Responsibility**: Main conversation UI
**Components**:
- `DocumentEditorView` — Primary conversation interface
- `SingleDocumentView` — Branch-specific message list
- `DocumentEditorViewModel` — State and actions for a branch
- `MessageRow` — Individual message rendering

**Stability**: Low (UI evolves with features)
**Dependencies**: SwiftUI, Core modules

#### `Sources/Features/Sidebar/`
**Responsibility**: Navigation and tree management  
**Components**:
- `SidebarView` — Tree/branch navigation
- `SidebarViewModel` — Tree loading and selection
- `TreeNodeView` — Recursive tree renderer

**Stability**: Low (UI)  
**Dependencies**: SwiftUI, Core modules

---

## Planned Extensions

### Phase 1: Project Intelligence Layer

#### New Module: `Sources/Core/Projects/`
**Responsibility**: Project discovery, metadata caching, context loading

**Components**:
```swift
// Discovery
class ProjectScanner {
    func scanDirectory(_ url: URL) async throws -> [DiscoveredProject]
}

struct DiscoveredProject {
    let path: URL
    let name: String
    let type: ProjectType // Swift, Rust, TypeScript, etc.
    let gitStatus: GitStatus?
    let lastModified: Date
}

// Cache
actor ProjectCache {
    func update(_ project: DiscoveredProject) async
    func get(_ name: String) async -> CachedProject?
    func getAll() async -> [CachedProject]
}

struct CachedProject {
    let project: DiscoveredProject
    let recentFiles: [URL]
    let openBranches: [String]
    let cachedAt: Date
}

// Context Loader
class ProjectContextLoader {
    func loadContext(for projectName: String) async throws -> ProjectContext
}

struct ProjectContext {
    let project: CachedProject
    let structure: [String] // Key directories
    let readme: String?
    let recentCommits: [String]
}
```

**Database Schema Addition**:
```sql
CREATE TABLE project_cache (
    name TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    type TEXT NOT NULL,
    git_branch TEXT,
    git_dirty INTEGER DEFAULT 0,
    last_scanned TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON
);

CREATE TABLE project_files (
    project_name TEXT NOT NULL REFERENCES project_cache(name),
    file_path TEXT NOT NULL,
    last_accessed TIMESTAMP,
    PRIMARY KEY (project_name, file_path)
);
```

**Dependencies**: Foundation, GRDB  
**Stability**: High (interface), Medium (implementation)

---

### Phase 2: Terminal Integration Layer

#### New Module: `Sources/Core/Terminals/`
**Responsibility**: Terminal discovery, output capture, command injection

**Components**:
```swift
// Discovery
class TerminalDiscovery {
    func listActiveSessions() async throws -> [TerminalSession]
}

struct TerminalSession: Identifiable {
    let id: String // tmux session name or PID
    let type: TerminalType // tmux, shell, IDE
    let workingDirectory: URL?
    let runningCommand: String?
    let pid: Int
}

enum TerminalType {
    case tmuxSession(name: String)
    case shell(pid: Int)
    case xcode(projectPath: URL)
}

// Output Capture
actor TerminalOutputCapture {
    func startCapture(sessionId: String) async throws
    func stopCapture(sessionId: String) async
    func getRecentOutput(sessionId: String, lines: Int) async -> String
}

// Command Injection
class TerminalCommandInjector {
    func send(_ command: String, to sessionId: String) async throws
}
```

**Integration Points**:
- Extend `ClaudeBridge` with terminal awareness
- Add new tools: `list_terminals`, `capture_output`, `send_to_terminal`
- UI: Terminal list view in sidebar or bottom panel

**Dependencies**: Foundation, tmux/shell process management  
**Stability**: Medium (external process interaction)

---

### Phase 3: Background Job System

#### New Module: `Sources/Core/Jobs/`
**Responsibility**: Async job scheduling, execution, and result surfacing

**Components**:
```swift
// Job Definition
struct BackgroundJob: Identifiable, Codable {
    let id: UUID
    let type: JobType
    let command: String
    let workingDirectory: URL
    var status: JobStatus
    var output: String?
    var error: String?
    let createdAt: Date
    var completedAt: Date?
}

enum JobType: String, Codable {
    case build, test, lint, script
}

enum JobStatus: String, Codable {
    case queued, running, completed, failed, cancelled
}

// Queue Manager
@MainActor
class JobQueue: ObservableObject {
    @Published var activeJobs: [BackgroundJob] = []
    
    func enqueue(_ job: BackgroundJob) async throws
    func cancel(_ jobId: UUID) async
    func getHistory(limit: Int) async -> [BackgroundJob]
}

// Executor (runs in Daemon)
actor JobExecutor {
    func execute(_ job: BackgroundJob) async -> JobResult
}

struct JobResult {
    let output: String
    let exitCode: Int
    let duration: TimeInterval
}
```

**Database Schema Addition**:
```sql
CREATE TABLE background_jobs (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    command TEXT NOT NULL,
    working_directory TEXT NOT NULL,
    status TEXT NOT NULL,
    output TEXT,
    error TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP
);
```

**UI Components**:
- `JobStatusBadge` — Inline spinner/checkmark in conversation
- `JobListView` — Sidebar panel showing active/recent jobs
- `JobDetailView` — Expandable output viewer

**Dependencies**: Foundation, GRDB, Daemon integration  
**Stability**: Medium

---

### Phase 4: Visual Verification Layer

#### New Module: `Sources/Core/Verification/`
**Responsibility**: Screenshot capture, inline rendering, visual diffs

**Components**:
```swift
// Screenshot Capture
class ScreenshotCapture {
    func captureSimulator(deviceId: String) async throws -> URL
    func captureWindow(windowId: Int) async throws -> URL
}

// Storage
actor ScreenshotStore {
    func save(_ image: URL, metadata: ScreenshotMetadata) async throws -> String
    func load(_ id: String) async throws -> URL
}

struct ScreenshotMetadata: Codable {
    let branchId: String
    let messageId: Int
    let deviceType: String?
    let timestamp: Date
}

// Inline Renderer (SwiftUI)
struct InlineImage: View {
    let imageURL: URL
    @State private var image: NSImage?
}
```

**Tool Extensions**:
```swift
// New tool: capture_screenshot
static let captureScreenshot = ToolSchema(
    name: "capture_screenshot",
    description: "Capture screenshot from iOS simulator or macOS window",
    inputSchema: JSONSchema(/*...*/)
)
```

**Database Schema Addition**:
```sql
CREATE TABLE screenshots (
    id TEXT PRIMARY KEY,
    branch_id TEXT NOT NULL REFERENCES canvas_branches(id),
    message_id INTEGER,
    file_path TEXT NOT NULL,
    device_type TEXT,
    captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**Dependencies**: Foundation, SwiftUI, GRDB  
**Stability**: Low (visual features evolve)

---

### Phase 5: Starfleet Integration

#### New Module: `Sources/Core/Starfleet/`
**Responsibility**: Crew compilation, agent invocation, memory updates

**Components**:
```swift
// Agent Compilation
class StarfleetCompiler {
    func compile(agent: String, mode: CompileMode) async throws -> CompiledAgent
}

enum CompileMode: String {
    case craft, systems, lean
}

struct CompiledAgent {
    let name: String
    let identity: String // Full compiled markdown
    let knowledgeFiles: [String: String]
    let memoryEntries: [String]
}

// Agent Invoker
class StarfleetBridge {
    func invoke(
        agent: String,
        task: String,
        context: [String: String]
    ) async throws -> AgentResult
}

struct AgentResult {
    let output: String
    let artifacts: [URL]
    let learnings: [String]
}

// Memory Writer
actor StarfleetMemory {
    func append(
        agent: String,
        entry: MemoryEntry
    ) async throws
}

struct MemoryEntry {
    let type: MemoryType // decision, correction, pattern
    let content: String
    let context: String?
    let timestamp: Date
}

enum MemoryType: String {
    case decision, correction, pattern, fix
}
```

**Integration**:
- Extend `ClaudeBridge` system prompt with agent identity when needed
- Auto-detect domain from task (architecture → Geordi, UI → Data, etc.)
- Post-task: append learnings to `~/.cortana/starfleet/crew/{agent}/MEMORY.md`

**Dependencies**: Foundation, FileManager (reads ~/.cortana/starfleet/)  
**Stability**: Medium (depends on external crew structure)

---

## Dependency Graph

```
App Layer (Features/)
    ↓
Core Domain (Core/Claude, Core/Database)
    ↓
Foundation (Swift stdlib, GRDB, URLSession)

New Layers:
Core/Projects → Core/Database
Core/Terminals → Foundation (process management)
Core/Jobs → Core/Database + Daemon
Core/Verification → Core/Database + Foundation
Core/Starfleet → Foundation (filesystem) + Core/Claude (context injection)
```

**Rules**:
- No circular dependencies
- Features don't import Features
- Core doesn't import Features
- Database is only imported by other Core modules, never Features directly

---

## Data Flow

### Current: Conversation Turn
```
User Input → BranchViewModel → ClaudeBridge
    ↓
AnthropicClient (API call)
    ↓
ToolExecutor (if tools requested)
    ↓
Response Stream → BranchViewModel → UI Update
    ↓
MessageStore (persist)
```

### Future: Conversation Turn with Intelligence
```
User Input → BranchViewModel → ClaudeBridge
    ↓
[NEW] ProjectContext injection
    ↓
[NEW] Starfleet agent detection (if needed)
    ↓
AnthropicClient (API call with enriched context)
    ↓
ToolExecutor (expanded tool set)
    ↓
[NEW] Background job spawning (if long-running)
    ↓
Response Stream → BranchViewModel → UI Update
    ↓
MessageStore + [NEW] JobQueue + [NEW] ProjectCache updates
```

---

## UI Architecture (Data's Domain)

### Current Layout
```
┌───────────────────────────────────────────┐
│ Sidebar (30%)   │  Document (70%)         │
│                 │                         │
│ Tree List       │  Branch Messages        │
│  - Branch 1     │   - User message        │
│  - Branch 2     │   - Assistant response  │
│                 │   - Tool activity       │
│                 │                         │
└───────────────────────────────────────────┘
```

### Evolved Layout (Phase 2+)
```
┌───────────────────────────────────────────────────────────┐
│ Top Bar: Project Switcher | Active Jobs (3) | Daemon (●) │
├─────────────────────┬─────────────────────────────────────┤
│ Sidebar (25%)       │  Document (50%) │  Inspector (25%) │
│                     │                │                   │
│ Projects            │  Messages      │  Active Job       │
│  - World Tree       │   - User       │   ┌─────────────┐ │
│  - BookBuddy        │   - Assistant  │   │ Build...    │ │
│                     │   - Tool       │   │ [progress]  │ │
│ Terminals           │                │   └─────────────┘ │
│  - tmux:dev         │  Screenshot    │                   │
│  - shell:1234       │   [inline img] │  Context          │
│                     │                │   - Files (5)     │
│ History             │                │   - Git: main     │
│  - Branch 1         │                │                   │
│  - Branch 2         │                │                   │
└─────────────────────┴────────────────┴───────────────────┘
```

### New UI Components Needed
- `ProjectSwitcherButton` (top bar)
- `JobStatusIndicator` (top bar + inline)
- `TerminalListView` (sidebar panel)
- `TerminalOutputView` (inspector)
- `InlineScreenshot` (canvas message attachment)
- `ProjectContextPanel` (inspector)
- `BackgroundJobPanel` (inspector or bottom drawer)

---

## Testing Strategy (Worf's Domain)

### Existing Coverage
- **Unit tests**: None yet (bootstrapped quickly)
- **Integration tests**: None
- **UI tests**: None

### Required Before Shipping Phases
1. **Phase 1** (Project Intelligence):
   - Unit: ProjectScanner finds all project types correctly
   - Unit: ProjectCache handles concurrent access safely
   - Integration: Full scan → cache → context load pipeline

2. **Phase 2** (Terminal Integration):
   - Unit: TerminalDiscovery parses tmux/ps correctly
   - Integration: Output capture doesn't miss lines
   - Safety: Command injection is sandboxed to correct session

3. **Phase 3** (Background Jobs):
   - Unit: JobQueue handles cancellation gracefully
   - Integration: Job executor reports progress correctly
   - Safety: Jobs can't escape working directory without explicit permission

4. **Phase 4** (Visual Verification):
   - Unit: Screenshot capture handles missing simulator
   - Integration: Image storage + retrieval preserves quality
   - UI: Images load asynchronously without blocking conversation

5. **Phase 5** (Starfleet):
   - Unit: Agent compilation doesn't fail on missing files
   - Integration: Memory append is atomic (no corrupt MEMORY.md)
   - Safety: Agent invocation times out if hung

---

## Performance Considerations (Torres's Domain)

### Current Bottlenecks
- Database writes block UI during message save
- Large tool outputs (>10KB) slow down API responses
- No pagination on message history (loads all messages)

### Optimizations for New Features
1. **Project Cache**: Scan in background, don't block startup
2. **Terminal Capture**: Circular buffer (last 1000 lines) to avoid memory growth
3. **Background Jobs**: Offload execution to daemon (no UI blocking)
4. **Screenshots**: Async capture + thumbnail generation
5. **Starfleet**: Lazy compilation (compile agent only when invoked)

### Performance Budget
- UI stays responsive (<16ms frame time)
- Database queries < 100ms
- Tool execution isolated (won't freeze UI)
- API streaming updates every 100ms (not every token)

---

## Migration Path

### Phase-by-Phase Rollout
1. **Phase 1** (Project Intelligence): Non-breaking addition
   - New tables, new modules, new UI components
   - Existing features unaffected
   
2. **Phase 2** (Terminal Integration): Additive
   - New tools exposed to Claude
   - Sidebar gets new panel

3. **Phase 3** (Background Jobs): Refactor tool execution
   - **Breaking change**: Long-running commands move to job queue
   - Migration: Detect commands > 10s, auto-queue
   
4. **Phase 4** (Visual Verification): Additive
   - New tool + rendering layer

5. **Phase 5** (Starfleet): Context injection changes
   - **Breaking change**: System prompt structure evolves
   - Migration: Detect agent invocation keywords, inject compiled identity

### Rollback Strategy
- Each phase is feature-flagged
- Database migrations are reversible (have DOWN migrations)
- Old conversation branches remain functional (no schema breakage)

---

## Open Questions

### For Geordi (Architecture)
- Should ProjectCache be SQLite or JSON files? (Leaning SQLite for query speed)
- Terminal integration: parse output or use PTY library? (Parsing is simpler)
- Background jobs: extend daemon or separate service? (Extend daemon)

### For Data (UX)
- How to show multiple active jobs without clutter? (Inspector panel + top bar badge)
- Inline screenshots: full-size or thumbnail first? (Thumbnail + click to expand)
- Project switcher: dropdown or command palette? (Command palette ⌘P)

### For Spock (Strategy)
- Can we ship Phase 1-2 together? (Yes, they're orthogonal)
- Should Phase 3 block Phase 4? (No, visual verification is independent)
- When do we dogfood this ourselves? (After Phase 1 + 2)

---

## Success Metrics

### Objective Measures
- **Context switching time**: < 2 seconds to load any project
- **Terminal visibility**: All active processes visible in UI
- **Background job latency**: Jobs start within 1 second of request
- **Screenshot capture**: < 500ms from request to display
- **Agent invocation**: Transparent (user doesn't notice)

### Subjective Measures
- **Evan's reaction**: "This is better than Ghostty + tmux"
- **Workflow change**: Canvas becomes primary development window
- **Context loss**: Zero — never need to re-explain project state

---

*Architecture shaped by Geordi. Execution begins with Phase 1.* 💠

*Architecture shaped by Geordi. Execution begins with Phase 1.* 💠

---

## Pencil Intelligence Layer (EPIC-007)

Connects Pencil.dev design frames to World Tree tickets. Read-only — World Tree never mutates canvas state.

### Modules

| File | Role |
|------|------|
| `Sources/Core/Pencil/PencilMCPClient.swift` | stdio MCP client — spawns Pencil binary, communicates via JSON-RPC 2.0 |
| `Sources/Core/Pencil/PencilModels.swift` | Codable value types for `.pen` JSON schema |
| `Sources/Core/Pencil/PencilConnectionStore.swift` | `@MainActor ObservableObject` — connection state, last editor state, last layout |
| `Sources/Features/CommandCenter/PencilDesignSection.swift` | "Design" tab in Command Center — frame list, ticket badges |
| `Sources/Features/Settings/PencilSettingsView.swift` | URL config, feature toggle, import trigger |
| `Sources/Core/Pencil/WORLDTREE_MCP_TOOLS.md` | Claude Code reference — tool contracts + annotation convention |

### Database Tables

| Table | Purpose |
|-------|---------|
| `pen_assets` | Imported `.pen` files — id, project, file_name, file_path, frame_count, node_count, last_parsed |
| `pen_frame_links` | Frame → ticket FK — pen_asset_id, frame_id, frame_name, ticket_id |

### Three MCP Tools (Phase 3)

| Tool | Input | Purpose |
|------|-------|---------|
| `world_tree_list_pen_assets` | `{ project? }` | List imported `.pen` files for a project |
| `world_tree_get_frame_ticket` | `{ frame_id, pen_asset_id }` | Resolve a frame to its TASK ticket |
| `world_tree_list_ticket_frames` | `{ ticket_id, project }` | Find design frames for a ticket |
| `world_tree_frame_screenshot` | `{ frame_id, pen_asset_id }` | Capture live PNG of a frame — returns MCP image block |

### Phase Roadmap

```
Phase 1 — MCP Client       PencilMCPClient, models, connection store, UI shell          ✓ Done
Phase 2 — .pen File Support DB tables, file import, frame→ticket linking, inspector      ✓ Done
Phase 3 — World Tree MCP   3 read-only tools in PluginServer                            ✓ Done
Phase 4 — Visual Verify    FS watcher, frame screenshots, preview panel, visual diff    ✓ Done
```

### Phase 4 Deliverables

| Deliverable | File | Notes |
|-------------|------|-------|
| Filesystem watcher | `PencilConnectionStore` | `DispatchSource` dir-level, <2s re-import |
| `getFrameScreenshot` | `PencilMCPClient` | `set_selection` + `get_screenshot` |
| Screenshot cache | `PencilConnectionStore` | In-memory `[String: Data]`, cleared on disconnect |
| Frame preview panel | `PencilDesignSection / PencilFrameRow` | Expandable inline thumbnail, max 300pt |
| Visual diff view | `PencilDiffView` | `HSplitView` — Pencil frame vs frontmost app window |
| MCP screenshot tool | `PluginServer` | `world_tree_frame_screenshot` → MCP image block |

### Annotation Convention

Frames link to tickets via Pencil's `annotation` field. Set annotation to `TASK-067` (exact, case-sensitive). World Tree auto-resolves on next `.pen` import.

### Design Invariants

- **Read-only.** Canvas authority stays in Pencil.
- **Auto-import via FS watcher.** `DispatchSource` watches each `.pen` file's directory. Saves auto re-import within 2 seconds of any change.
- **Binary discovery:** UserDefaults override → `/Applications/Pencil.app` → `~/.vscode/extensions/` → `~/.cursor/extensions/`

*Pencil layer: Phases 1–4 complete. 💠*
