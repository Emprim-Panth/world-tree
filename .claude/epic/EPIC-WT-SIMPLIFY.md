# EPIC-WT-SIMPLIFY: World Tree — Knowledge Server Rebuild

**Status:** Planning
**Priority:** High
**Owner:** Evan
**Created:** 2026-03-23
**Tasks:** TASK-9 through TASK-23

---

## PRD — Product Requirements Document

### Problem Statement

World Tree was designed to be the single terminal replacement: chat client, terminal emulator, background job runner, project scanner, visual verification tool, design viewer, and dispatch center simultaneously. The result is an app that:

- **Crashes repeatedly** due to CDHash invalidation (TCC screen recording grant lost on every rebuild), SIGTERM race conditions, and WAL contention with cortana-core
- **Consumes disproportionate maintenance tokens** — a significant fraction of every session is spent diagnosing or recovering from World Tree crashes rather than building product
- **Externalizes no memory** — all session context lives in the Claude context window, which compacts and dies. Knowledge loss is structural, not incidental
- **Competes poorly with its rivals** — it is a worse chat client than Claude Desktop, a worse terminal than Ghostty, and a worse job runner than the gateway. It wins nowhere

The NERVE, Factory Floor, branch tree, streaming pipeline, Pencil design viewer, daemon IPC, and LLM provider abstraction layers are each individually complex enough to produce crashes. Together they form a system where any single component failure takes down the entire app.

### Goals

1. **Stable, crash-free operation** — World Tree runs for weeks without intervention. No CDHash issues. No TCC grants. No daemon sockets.
2. **Command Center** — Native macOS dashboard showing all project states, dispatch activity, and system health. Read-only consumer of the gateway and compass DB.
3. **Ticket Master** — TASK-*.md file viewer and status editor. The single place Evan reviews and updates work across all projects.
4. **Brain Resource** — Filesystem-based BRAIN.md viewer and editor for every project. Sessions pull context from World Tree's HTTP API instead of carrying it in context windows.
5. **Anti-compaction architecture** — Sessions are stateless compute that pull compressed context at start and push summaries at end. Memory lives in World Tree, not in token windows.

### Non-Goals

The following will **not** be built or maintained in World Tree after this epic:

| Feature | Reason | Alternative |
|---------|--------|-------------|
| Chat / conversation UI | Claude Desktop is better and always will be | Claude Desktop |
| Branch tree | Only exists to support chat UI | Deleted with it |
| Terminal emulator | Ghostty + tmux are better | Ghostty |
| Background job execution | Gateway already does this | `POST /v1/cortana/dispatch` |
| Visual verification / screenshots | CDHash tax, Peekaboo instability | Direct simctl in terminal |
| Pencil design integration | Standalone MCP tool is the right scope | Pencil MCP server |
| LLM provider abstraction | World Tree is not a chat client anymore | N/A |
| Starfleet agent invocation | `cortana-compile` in terminal | `cortana-compile` |
| Daemon Unix socket IPC | Removing daemon dependency entirely | Gateway HTTP API |
| Token tracking | Belongs in gateway | Gateway |
| Voice input | Belongs in a dedicated input surface | N/A |

### Success Metrics

| Metric | Before | Target |
|--------|--------|--------|
| Crash-free run duration | Hours to days | 2+ weeks without intervention |
| Files in Sources/ | 212 | < 40 |
| Core modules | 24 | 5 |
| Feature modules | 15 | 4 |
| Maintenance tokens per week (WT bugs) | High | Near-zero |
| Session context compaction losses | Frequent | Eliminated (context pulled fresh) |
| Time to understand codebase | Hours | 30 minutes |

### User Stories

1. **As Evan**, I open World Tree and see all 8 projects with their current phase, git state, and open ticket count — without the app having crashed since last week.
2. **As Evan**, I click on BookBuddy in the Command Center and immediately see its open tickets, can update a ticket status, and read the current BRAIN.md — all without typing a thing to Claude.
3. **As a new Claude session**, I call `GET /context/BookBuddy` and receive a compressed project brief under 1500 tokens. I never ask Evan to re-explain the project.
4. **As a Claude session approaching context limit**, I POST my session summary to World Tree and pull a fresh brief. Work continues without memory loss. Compaction is irrelevant.
5. **As Evan**, I update a BRAIN.md directly in World Tree's editor, and the change is immediately reflected in the next session that pulls context — no manual file editing in terminal.

---

## FRD — Functional Requirements Document

### Architecture: Before → After

**Before (current):**
```
World Tree (212 Swift files, 24 Core modules, 15 Feature modules)
├── Chat engine (AnthropicClient, ClaudeBridge, providers, tools, sandbox)
├── Branch tree (conversation trees, branching, context management)
├── Terminal emulator (SwiftTerm, BranchTerminalManager)
├── Daemon IPC (Unix socket, DaemonSocket, LogTailer)
├── Job execution (JobQueue, JobExecutor, streaming)
├── Design viewer (PencilMCPClient, PencilConnectionStore, frame links)
├── Security layer (ApprovalCoordinator, ToolGuard, PermissionStore)
├── Provider abstraction (16 provider files, OllamaClient, CodexCLI)
├── WebSocket server (TokenBroadcaster, SubscriptionManager)
├── Command Center (Compass cards + 12 embedded sections)
└── Tickets (AllTicketsView, TicketListView)

Crash surfaces: CDHash/TCC, SIGTERM races, WAL contention,
                daemon socket drops, streaming races, provider auth
```

**After (target):**
```
World Tree (~35 Swift files, 5 Core modules, 4 Feature modules)
├── Core/Database/        — GRDB, canvas_tickets, canvas_dispatches, compass read
├── Core/Gateway/         — GatewayClient (read dispatch + project state)
├── Core/BrainHost/       — Filesystem BRAIN.md reader/writer
├── Core/ContextServer/   — HTTP server: GET /context/:project, POST endpoints
├── Core/Models/          — ProjectBrief, Ticket, Dispatch (minimal)
├── Features/CommandCenter/ — Project cards, dispatch activity (slimmed)
├── Features/Tickets/     — TASK-*.md viewer + status editor
├── Features/Brain/       — BRAIN.md editor per project
└── Features/Settings/    — Minimal config

Crash surfaces: SQLite WAL (already solved) — nothing else
```

### Deletion Manifest

Every module not listed in "Keep" is deleted. No exceptions. No "keep for reference."

#### Core Modules — DELETE ALL

| Module | Files | Reason |
|--------|-------|--------|
| `Core/Claude/` | 8 files | Entire chat engine. No chat = no chat engine. |
| `Core/Branching/` | 2 files | Branch tree only exists for chat UI. |
| `Core/Cache/` | 1 file | StreamCacheManager — stream infra gone. |
| `Core/Context/` | 9 files | Context windowing, send context builder, session rotator — all chat. |
| `Core/Coordinator/` | 2 files | Session coordination for chat. |
| `Core/Cortana/` | 1 file | CortanaPlannerStore — workflow planner for chat dispatch. |
| `Core/Daemon/` | 5 files | Unix socket IPC. We use HTTP (gateway) instead. |
| `Core/Jobs/` | 3 files | Background job execution. Gateway handles this. |
| `Core/Pencil/` | 3 files | Design integration. Separate MCP tool. |
| `Core/Plugin/` | 1 file | PluginServer — MCP plugin server for chat tools. |
| `Core/ProjectDocs/` | 1 file | ProjectDocsStore — superseded by BrainHost. |
| `Core/ProjectIntelligence/` | 6 files | Project scanner/cache — superseded by gateway context endpoint. |
| `Core/Providers/` | 16 files | LLM provider abstraction. No LLM calls from WT. |
| `Core/Sandbox/` | 1 file | Tool execution sandbox. No tool execution. |
| `Core/Security/` | 5 files | Tool approval UI. No tools. |
| `Core/Server/` | 6 files | PeekabooBridge, WebSocket, token broadcaster. Delete all; replace with ContextServer. |
| `Core/SlashCommands/` | 1 file | Slash command registry for chat. |
| `Core/Terminal/` | 1 file | BranchTerminalManager. No terminal. |
| `Core/Voice/` | 1 file | VoiceService. No voice. |
| `Core/Brain/` | 1 file | BrainStore — chat knowledge store. Replace with BrainHost (filesystem). |
| `Core/Events/` | 1 file | WorldTreeEvent — stream event types for chat. |
| `Core/GlobalHotKey.swift` | 1 file | Global hotkey for chat input. |
| `Core/PermissionsService.swift` | 1 file | macOS permission requests for TCC. No TCC needed. |

#### Core Modules — KEEP (trimmed)

| Module | Files | Keep Reason |
|--------|-------|------------|
| `Core/Database/DatabaseManager.swift` | 1 | GRDB connection, WAL mode |
| `Core/Database/CompassStore.swift` | 1 | Reads compass.db for project state |
| `Core/Database/HeartbeatStore.swift` | 1 | Reads heartbeat_runs for system status |
| `Core/Database/TicketStore.swift` | 1 | canvas_tickets CRUD |
| `Core/Database/SessionStateStore.swift` | 1 | Read-only view of active session state |
| `Core/Database/MigrationManager.swift` | 1 | **Trimmed** — keep only canvas_tickets + canvas_dispatches migrations |
| `Core/DispatchActivityStore.swift` | 1 | Reads canvas_dispatches for activity feed |
| `Core/Gateway/GatewayClient.swift` | 1 | HTTP client for gateway (project state, dispatches) |
| `Core/CrashSentinel.swift` | 1 | Sentinel file write every 30s (keep — low cost, high value) |
| `Core/WakeLock.swift` | 1 | Prevents system sleep. Keep. |
| `Core/Notifications/NotificationManager.swift` | 1 | macOS user notifications for dispatch completion |

#### Database Stores — DELETE

| Store | Reason |
|-------|--------|
| `MessageStore.swift` | Chat messages. No chat. |
| `TreeStore.swift` | Conversation trees. No chat. |
| `AgentStatusStore.swift` | Agent session tracking for chat dispatch. |
| `AttentionStore.swift` | Agent attention events for chat routing. |
| `AutoDecisionStore.swift` | Autonomous decision audit trail. Belongs in gateway. |
| `ConflictDetector.swift` | Message conflict detection in chat. |
| `DiffReviewStore.swift` | Code diff review in chat. Belongs in gateway. |
| `EventRuleStore.swift` | Event rules for chat automation. Belongs in cortana-core. |
| `GraphStore.swift` | Knowledge graph for chat. |
| `PenAssetStore.swift` | Pencil .pen file imports. Pencil gone. |
| `TimelineStore.swift` | Unified timeline for chat + dispatch. Belongs in gateway. |
| `TokenStore.swift` | Token usage tracking. Belongs in gateway. |
| `UIStateStore.swift` | Chat UI state persistence. |

#### MigrationManager — TRIM

Keep migrations for: `canvas_tickets`, `canvas_dispatches`
Delete migrations for: `canvas_trees`, `canvas_branches`, `canvas_jobs`, `pen_assets`, `pen_frame_links`, `background_jobs`, and all message/session/token schema

#### Features — DELETE ALL

| Feature | Files | Reason |
|---------|-------|--------|
| `Features/Agents/` | 3 files | Starfleet dispatch UI. Use `cortana-compile` in terminal. |
| `Features/Brain/BrainView.swift` | 1 file | Chat knowledge inspector. Replace with BrainEditorView. |
| `Features/Brain/KnowledgeView.swift` | 1 file | Chat knowledge search. Delete. |
| `Features/Canvas/` | 0 files | Directory only (already empty or merged into Document). |
| `Features/Context/ContextInspectorView.swift` | 1 file | Chat context window inspector. No chat. |
| `Features/Cortana/` | unknown | Cortana chat identity integration. Delete. |
| `Features/Dashboard/EventTimelineView.swift` | 1 file | Unified event timeline. Belongs in gateway console. |
| `Features/Dashboard/GlobalSearchView.swift` | 1 file | Chat + knowledge search. |
| `Features/Document/` | 5 files | Conversation document view. Primary chat UI. Delete entirely. |
| `Features/MCPTools/` | 3 files | MCP configuration for chat tools. |
| `Features/Projects/` | 3 files | Project docs viewer. Superseded by Brain editor. |
| `Features/Sidebar/` | 4 files | Conversation tree sidebar. No tree. |
| `Features/Templates/` | 2 files | Workflow templates for chat. |
| `Features/Terminal/TerminalView.swift` | 1 file | Terminal emulator view. No terminal. |

#### CommandCenter Sections — DELETE

These sections are embedded in Features/CommandCenter but reference deleted systems:

| Section | Delete Reason |
|---------|--------------|
| `ActiveWorkSection.swift` | References live branches and chat sessions |
| `AgentStatusBoard.swift` + `AgentStatusCard.swift` | Agent session tracking for chat |
| `AttentionPanel.swift` | Agent attention events |
| `ConflictWarningBanner.swift` | Chat message conflict detection |
| `CoordinatorSection.swift` | Session coordinator for chat |
| `CortanaOpsSection.swift` | Cortana workflow operations via chat |
| `DecisionReviewSection.swift` + `DiffReviewSheet.swift` + `DiffReviewView.swift` | Code diff review in chat |
| `EventRulesSheet.swift` | Event rules automation |
| `FactoryFloorView.swift` + `FactoryPipelineView.swift` | NERVE factory pipeline |
| `JobOutputInspectorView.swift` | Background job output viewer |
| `LiveStreamsSection.swift` | Live streaming sessions |
| `PencilDesignSection.swift` + `PencilDiffView.swift` | Pencil design integration |
| `SessionHealthBadge.swift` + `SessionMemoryView.swift` | Chat session health |
| `StarfleetActivitySection.swift` | Crew dispatch via chat |
| `TokenDashboardView.swift` | Token usage (belongs in gateway) |

#### CommandCenter Sections — KEEP (trimmed)

| Section | Keep Reason |
|---------|------------|
| `CommandCenterView.swift` | Main view — rebuild around kept sections |
| `CommandCenterViewModel.swift` | Trim to compass + dispatch data only |
| `CompassProjectCard.swift` | Project state cards — core UI |
| `DispatchActivityView.swift` | Crew dispatch activity feed |
| `DispatchSheet.swift` | Manual dispatch trigger (can stay) |

#### Shared — DELETE

| File | Reason |
|------|--------|
| `ActiveStreamRegistry.swift` | Stream registry for chat streaming |
| `BranchWindowOwnershipRegistry.swift` | Branch window tracking for chat |
| `Components/ArtifactRendererView.swift` | Renders tool output artifacts in chat |
| `Components/ChoiceBlockView.swift` | Choice blocks in chat UI |
| `Components/CodeBlockView.swift` | Code blocks in chat messages |
| `Components/ContextGauge.swift` | Context window gauge in chat |
| `Components/DiffView.swift` | Inline diff viewer in chat |
| `Components/KeyboardHandlingTextEditor.swift` | Chat input editor |
| `Components/ModelBadge.swift` | LLM model badge in chat |
| `Components/ProviderBadge.swift` | Provider badge in chat |
| `Components/WebViewPool.swift` | Web view pool for rendering chat content |
| `FactoryStatusChip.swift` | Factory pipeline status chip |
| `GlobalStreamRegistry.swift` | Global stream registry |
| `KeychainHelper.swift` | API key storage. No API calls from WT. |
| `LocalAgentIdentity.swift` | Local agent identity for chat sessions |
| `ModelPickerButton.swift` | Model picker for chat |
| `OpenAIKeyStore.swift` | OpenAI key storage. No LLM calls. |
| `ProcessingRegistry.swift` | Tracks in-flight chat operations |
| `StreamRecoveryCoordinator.swift` | Stream recovery for chat |
| `StreamRecoveryStore.swift` | Stream recovery state for chat |

#### Shared — KEEP

| File | Keep Reason |
|------|------------|
| `Components/StatusBadge.swift` | Generic status badge — used in Tickets + CommandCenter |
| `Components/HeartbeatIndicator.swift` | Heartbeat status dot |
| `Utilities.swift` | General utilities |
| `Constants.swift` | App-wide constants |
| `Utilities/AnyCodable.swift` | JSON decoding utility |

#### Models — DELETE

| Model | Reason |
|-------|--------|
| `AgentFileTouch.swift` | Agent session file tracking |
| `AgentSession.swift` | Chat agent session state |
| `AttentionEvent.swift` | Agent attention routing |
| `Branch.swift` | Conversation branch |
| `ConversationTree.swift` | Conversation tree |
| `DaemonStatus.swift` | Daemon IPC status |
| `EventRule.swift` | Event automation rule |
| `GlobalSearchResult.swift` | Global search result |
| `Message.swift` | Chat message |
| `NERVEModels.swift` | NERVE factory models |
| `ProposedWorkArtifact.swift` | Work artifact from chat |
| `SessionHealth.swift` | Chat session health |
| `StarfleetRoster.swift` | Crew roster display model |
| `TokenAggregates.swift` | Token usage aggregates |
| `ToolActivity.swift` | Tool execution activity in chat |
| `UnifiedTimelineEvent.swift` | Unified timeline event |

#### Models — KEEP

| Model | Keep Reason |
|-------|------------|
| `Dispatch.swift` | canvas_dispatches model |

#### New Models to Build

| Model | Purpose |
|-------|---------|
| `ProjectBrief.swift` | Response model for `GET /context/:project` |
| `BrainFile.swift` | BRAIN.md metadata + content model |

#### Dependencies — project.yml

| Package | Action | Reason |
|---------|--------|--------|
| `GRDB.swift` | **Keep** | Database layer |
| `SwiftTerm` | **Delete** | Terminal emulator. No terminal. |

---

### New Feature Specifications

#### 1. BrainHost (`Core/BrainHost/`)

**Purpose:** Filesystem-based reader/writer for BRAIN.md files across all projects. The authoritative source for session context injection.

**Files:**
- `BrainFileStore.swift` — discovers all `{project}/.claude/BRAIN.md` files under `~/Development/`, reads and writes them. Uses `FileManager` + `DispatchSource` for filesystem watching (2s re-read on change).

**Interface:**
```swift
actor BrainFileStore {
    func allProjects() async -> [String]
    func read(project: String) async throws -> String        // raw markdown
    func write(project: String, content: String) async throws
    func watch(project: String, onChange: @escaping () -> Void) -> FileWatchHandle
}
```

**Constraints:**
- Read/write directly to `{project}/.claude/BRAIN.md`
- No DB involvement — filesystem is the source of truth
- Watch only the directories of actively viewed projects (not all 8)

---

#### 2. ContextServer (`Core/ContextServer/`)

**Purpose:** Lightweight HTTP server that sessions query for project context. Replaces context-in-window with pull-on-demand.

**Files:**
- `ContextServer.swift` — starts an HTTP server on `127.0.0.1:4863`. Sessions call it at session start, mid-session when approaching limits, and at session end.
- `ContextRoutes.swift` — route handlers

**API Contracts:**

```
GET /context/:project
  → 200 { project, phase, milestone, brain_excerpt, open_tickets[], recent_dispatches[], blockers[] }
  → brief is pre-compressed to < 1500 tokens
  → brain_excerpt is the first 800 tokens of BRAIN.md

POST /brain/:project/update
  Body: { section: string, content: string }
  → Appends or replaces a named section in BRAIN.md
  → Used by sessions to write back decisions/corrections

POST /session/summary
  Body: { project: string, summary: string, decisions: string[], corrections: string[] }
  → Appends to BRAIN.md "Recent Sessions" section
  → Optionally writes to cortana-cli memory log
  → Returns 200 OK

GET /health
  → 200 { status: "ok", uptime: seconds }
```

**Auth:** Same token as gateway (`~/.cortana/ark-gateway.toml` `auth_token`). Header: `x-cortana-token`.

**Port:** 4863 (gateway is 4862, terminals are 4890)

**Constraints:**
- No persistence — all reads from filesystem (BRAIN.md) and compass.db
- Starts with the app, stops when app quits
- No dependency on gateway being up (reads BRAIN.md directly)

---

#### 3. BrainEditorView (`Features/Brain/BrainEditorView.swift`)

**Purpose:** Native macOS markdown editor for BRAIN.md files. Replaces terminal-based editing.

**Spec:**
- Project picker in sidebar (populated from BrainFileStore.allProjects())
- Left pane: raw markdown editor (TextEditor with monospace font, live autosave on 1s debounce)
- Right pane: rendered markdown preview (WKWebView with sanitized HTML)
- Status bar: last modified timestamp, character count
- No rich editor, no syntax highlighting required — plain TextEditor is sufficient

**Constraints:**
- Autosave debounced at 1 second (no save button)
- Conflict detection: if file modified externally while open, show banner "File changed externally — reload?"
- Never corrupt BRAIN.md — write to `.brain.tmp`, then atomic rename

---

### Retained Feature Specifications

#### CommandCenter (trimmed)

**Keeps:**
- `CompassProjectCard` — project name, phase, git branch, git dirty flag, open ticket count, last heartbeat
- `DispatchActivityView` — list of canvas_dispatches (project, model, status, result_text, completed_at)
- `DispatchSheet` — manual dispatch trigger to gateway

**Removes:**
- All 17 sections listed in deletion manifest above

**Layout:**
```
CommandCenter
├── Project Grid (2-column, CompassProjectCard × N)
└── Dispatch Activity (chronological list, last 50 entries)
```

#### Tickets (unchanged interface, trimmed backing)

**Keeps:**
- `AllTicketsView` — all open tickets across all projects
- `TicketListView` — tickets for a specific project

**Implementation note:** TicketStore reads `canvas_tickets` (synced from TASK-*.md by compass). No changes needed — this is already working.

#### Settings (trimmed)

**Keeps:**
- Gateway URL config
- Context server port config
- LaunchAgent control (stop/start World Tree)

**Removes:**
- Provider/API key config (CortanaControlMatrix, CortanaControlView)
- Pencil settings (PencilSettingsView)

---

### Data Model — Tables to Keep

| Table | Owner | Purpose |
|-------|-------|---------|
| `canvas_tickets` | World Tree | Ticket sync from TASK-*.md files |
| `canvas_dispatches` | World Tree | Crew dispatch activity feed |

**Tables to stop writing / orphan:**
| Table | Action |
|-------|--------|
| `canvas_trees` | Stop writing. Existing data abandoned. Migration removes foreign keys. |
| `canvas_branches` | Stop writing. Same. |
| `canvas_jobs` | Stop writing. Same. |
| `pen_assets` | Stop writing. Same. |
| `pen_frame_links` | Stop writing. Same. |

**Tables owned by cortana-core (read-only in WT):**
| Table | Purpose |
|-------|---------|
| `sessions` | Read for SessionStateStore display |
| `heartbeat_runs` | Read for HeartbeatStore |
| `compass.db` (external) | Read for CompassStore |

---

### Migration Plan

MigrationManager keeps only these migrations (all others deleted):
1. `v1_canvas_tickets` — create canvas_tickets
2. `v2_canvas_dispatches` — create canvas_dispatches

Migration to clean up orphaned tables:
3. `v3_drop_chat_tables` — `DROP TABLE IF EXISTS` for canvas_trees, canvas_branches, canvas_jobs, pen_assets, pen_frame_links

**No down migrations needed.** This is a one-way simplification.

---

### Session Integration Protocol

How sessions use World Tree as knowledge host:

**Session Start:**
```bash
# Hook: SessionStart (HookProcessor)
curl -s -H "x-cortana-token: $TOKEN" \
  http://127.0.0.1:4863/context/$PROJECT \
  | jq -r '.brain_excerpt + "\n\nOpen tickets:\n" + (.open_tickets | join("\n"))'
# Inject as system context
```

**Mid-Session (approaching context limit):**
```bash
# Session posts summary, pulls fresh brief
curl -s -X POST -H "x-cortana-token: $TOKEN" \
  http://127.0.0.1:4863/session/summary \
  -d '{"project":"BookBuddy","summary":"Fixed EPUB parser...","decisions":[]}'
# Then re-pull context
```

**Session End:**
```bash
# Hook: SessionEnd (HookProcessor)
curl -s -X POST -H "x-cortana-token: $TOKEN" \
  http://127.0.0.1:4863/session/summary \
  -d "$SESSION_SUMMARY_JSON"
```

This replaces all current context-in-window accumulation. Sessions never need to hold more than the current task + current exchange.

---

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Deletion breaks build (missing imports) | High | Medium | Delete in phases (Core first, Features second). Build after each phase. |
| CommandCenter loses functionality users depend on | Medium | Medium | Audit each section before deletion — screenshot current state |
| BrainHost writes corrupt BRAIN.md | Low | High | Atomic rename pattern (write .tmp, rename). Never in-place overwrite. |
| ContextServer port 4863 conflicts | Low | Low | Make port configurable in Settings |
| SessionEnd hook fails silently | Medium | Medium | Fire-and-forget with timeout — session end should never block |
| Compass.db schema changes break CompassStore | Medium | Medium | CompassStore uses read-only queries only — schema additions won't break it |

---

### LaunchAgent Changes

Current entitlements that can be **removed**:
- `com.apple.security.temporary-exception.files.home-relative-path.read-write` (for TCC access) — if used
- Screen recording / accessibility TCC grants — no longer needed with chat UI gone

Current entitlements to **keep**:
- `com.apple.security.network.server` — needed for ContextServer (port 4863)
- `com.apple.security.network.client` — needed for gateway HTTP calls

---

## Task Index

| Task | Title | Priority | Phase |
|------|-------|----------|-------|
| TASK-9 | Archive deprecated bug tickets (TASK-1 to TASK-8) | Medium | 0 — Housekeeping |
| TASK-10 | Delete Core chat modules | Critical | 1 — Deletion |
| TASK-11 | Delete Feature chat modules | Critical | 1 — Deletion |
| TASK-12 | Delete Shared chat infrastructure | Critical | 1 — Deletion |
| TASK-13 | Delete Database chat stores | Critical | 1 — Deletion |
| TASK-14 | Rebuild project.yml (remove SwiftTerm, clean sources) | Critical | 2 — Build stabilize |
| TASK-15 | Trim AppState to command center scope | High | 2 — Build stabilize |
| TASK-16 | Rebuild ContentView (3-panel: sidebar, center, detail) | High | 2 — Build stabilize |
| TASK-17 | Audit and trim CommandCenter (remove 17 deleted sections) | High | 2 — Build stabilize |
| TASK-18 | Build BrainHost (filesystem BRAIN.md reader/writer) | High | 3 — New features |
| TASK-19 | Build BrainEditorView (native SwiftUI markdown editor) | High | 3 — New features |
| TASK-20 | Build ContextServer (HTTP API for session context pull) | Critical | 3 — New features |
| TASK-21 | Wire SessionStart hook to pull from ContextServer | High | 4 — Integration |
| TASK-22 | Wire SessionEnd hook to POST summaries | High | 4 — Integration |
| TASK-23 | Update launchd plist and entitlements | Medium | 4 — Integration |

**Sequence constraint:** Phase 1 (deletions) must complete and build before Phase 2 starts. Phase 2 must stabilize before Phase 3. Phase 4 after Phase 3.

---

*EPIC-WT-SIMPLIFY. Planned 2026-03-23. 💠*
