# EPIC-CORTANA-HARNESS: The Cortana Harness — Persistent AI Runtime

**Status:** Planning
**Priority:** Critical
**Owner:** Evan
**Created:** 2026-04-02
**Tasks:** TASK-098 through TASK-112

---

## PRD — Product Requirements Document

### Problem Statement

The current system has five structural failures that compound into a single problem: **agent intelligence is fragmented, sessions are disposable, and knowledge doesn't flow.**

**1. Project files control agent behavior.** Each of 15+ project CLAUDE.md files shapes how agents think inside that directory. BIM Manager's CLAUDE.md teaches CPM scheduling. cortana-core's says "use GitNexus." When an agent crosses project boundaries, their personality and knowledge shifts based on which floor they're standing on. This means one project's agents work better than another's — not because of the work, but because of how the context was written.

**2. Knowledge is trapped in silos.** Agent workspaces (`~/.cortana/starfleet/crew/{agent}/`) don't auto-promote to brain/knowledge/. Brain project files are spotty (WorldTree: 15KB, cortana-core: 518 bytes). Two parallel ticket systems (.claude/epic/tasks/ vs compass.db canvas_tickets) drift apart. A pattern that works across three projects only becomes shared knowledge if someone manually writes it to brain/knowledge/patterns.md.

**3. The daemon is dead.** PID 3078 stale since 2026-03-27. Killed by gateway connection failures with no circuit breaker or exponential backoff. LaunchAgent not bootstrapped into launchd. No task queue polling, no gateway handoffs, no session orchestration. The persistence layer that was supposed to keep everything running has been offline for 6 days.

**4. Sessions are disposable.** Open terminal, Claude starts cold, hooks inject context, work, close, gone. `--resume` recovers conversation text but not reasoning state. No warm pool. No persistent thinking. Every session pays the full cold-start cost. No way to send instructions INTO a running session or get findings BACK without the session ending.

**5. No consolidation cycle.** Anthropic's leaked codebase reveals a Dream system — automated background memory consolidation with a 3-gate trigger (time + sessions + lock) and 4-phase processing (orient, gather, consolidate, prune). We have the write-back protocol documented in CLAUDE.md but it's manual, inconsistent, and depends on session discipline. Brain coverage drifts.

**Root cause:** The system grew organically. Each piece works in isolation but nothing enforces unified context, shared state, or automated maintenance. The architecture assumes disciplined manual handoffs between sessions — and that assumption fails under real workload.

### Goals

1. **Unified agent context.** Every agent session gets context from ONE compose function — not from whichever project CLAUDE.md they happen to be standing in. Project files become data inputs, not instruction overrides. Identity, corrections, and patterns are immutable across all projects.
2. **Shared real-time state.** Agents share findings, decisions, and blockers through a persistent scratchpad. Knowledge learned in one session is available to the next session immediately — without waiting for manual promotion.
3. **Persistent session pool.** Warm Claude Code sessions that survive terminal closures, app restarts, and idle periods. Sessions are rooms you walk in and out of. Tasks dispatch to warm sessions instantly, not cold starts.
4. **Bidirectional communication.** WorldTree can send instructions into running sessions and receive findings back in real time. This is the "chat" that's as durable as tmux — but backed by infrastructure, not a browser tab.
5. **Automated knowledge consolidation.** A Dream Engine that runs on a schedule, promotes patterns from scratchpad to brain, prunes stale entries, fills coverage gaps, and keeps the knowledge base healthy without human intervention.

### Non-Goals

| Feature | Reason Not In Scope | Alternative |
|---------|---------------------|-------------|
| Cross-machine sync | Single Mac Studio workstation for now | Revisit when second machine exists |
| Voice mode | Not priority for shipping products | KAIROS-style feature for later |
| Buddy/pet system | Fun but zero revenue impact | Never |
| New conversation UI | WorldTree IS the interface | Bridge provides the channel |
| Rewrite cortana-core from scratch | Load-bearing modules are solid | Port ~6500 lines, simplify the rest |
| Rewrite WorldTree Core layer | DatabaseManager, ContextServer, BrainIndexer are production quality | Keep Core, rebuild UI around harness |

### Success Metrics

| Metric | Before | Target |
|--------|--------|--------|
| Cold start time (session → useful context) | 15-30s (hooks + brain read + compass) | <3s (warm pool, context pre-loaded) |
| Knowledge promotion (scratchpad → brain) | Manual, inconsistent | Automated daily, zero manual steps |
| Cross-session knowledge availability | Next session only if brain was updated | Immediate via scratchpad |
| Daemon uptime | DEAD (0% since March 27) | 99.9% (circuit breakers, auto-restart) |
| Agent context consistency across projects | Varies by project CLAUDE.md | Identical compose function for all |
| Brain project coverage | 5 of 15 projects well-documented | All active projects documented |
| Session dispatch latency | Cold start every time | <1s from warm pool |

### User Stories

1. As **Evan**, I open WorldTree and see all running sessions, their current state, and can send a message into any of them — so I never lose track of what agents are doing.
2. As **Evan**, I dispatch a task and it starts within 1 second on a warm session — so background work doesn't wait for cold starts.
3. As **a Claude session**, I get the same identity, corrections, and patterns regardless of which project I'm working in — so I never give inconsistent advice.
4. As **a Claude session**, I write findings to the scratchpad and the next session working on the same project reads them immediately — so work doesn't repeat.
5. As **the Dream Engine**, I run every 24 hours, promote proven patterns, prune stale entries, and fill brain coverage gaps — so the knowledge base stays healthy without Evan touching it.

---

## FRD — Functional Requirements Document

### Architecture: Before -> After

**Before:**
```
Claude Code Session
  ├── reads ~/.claude/CLAUDE.md (global identity)
  ├── reads {project}/CLAUDE.md (project-specific, OVERRIDES behavior)
  ├── hooks inject: cortana-banner, cortana-hooks
  │     └── reads brain/, compass.db, knowledge base
  ├── MCP tools: cortana, scout, lcm, vision, gitnexus, etc.
  └── exits → knowledge stays in session or manual write-back

WorldTree (SwiftUI)
  ├── reads compass.db, conversations.db, brain-index.db
  ├── ContextServer on :4863 (one-way: sessions pull context)
  ├── TerminalLauncher (opens Ghostty+tmux, one-shot)
  └── no communication with running sessions

Daemon (Python) → DEAD
  ├── SessionManager (tmux dispatch, no warm pool)
  ├── TaskWatcher (filesystem queue polling)
  ├── GatewayPoller (no circuit breaker → crashed)
  └── CommandServer (unix socket RPC)

Knowledge Flow:
  session → manual write-back → brain/knowledge/ → next session reads it
  (breaks when write-back is forgotten, which is most of the time)
```

**After:**
```
CORTANA HARNESS (Bun daemon, always running)
  ├── Compose Layer
  │     └── ONE function builds agent context:
  │         global identity + brain corrections + brain patterns
  │         + project data (from CLAUDE.md, read-only)
  │         + active scratchpad entries
  │         + agent specialization (if Starfleet)
  │         = COMPILED CONTEXT (cached, invalidated on change)
  │
  ├── Session Pool
  │     ├── 2 warm Claude Code sessions (tmux, pre-loaded context)
  │     ├── dispatch to warm session: <1s
  │     ├── session finishes → returns to pool (re-compose context)
  │     └── health monitor: restart crashed sessions
  │
  ├── Shared Scratchpad (SQLite table in conversations.db)
  │     ├── agents write: findings, decisions, blockers
  │     ├── agents read: before starting work
  │     ├── keyed by: project + topic + timestamp
  │     └── auto-expires: 7 days (promoted entries persist in brain)
  │
  ├── Bridge (WebSocket on ContextServer)
  │     ├── WorldTree ↔ Harness: bidirectional
  │     ├── send instruction → running session
  │     ├── receive findings ← running session
  │     └── session state changes push to WorldTree
  │
  ├── Dream Engine (scheduled, launchd)
  │     ├── 3-gate trigger: 24h since last + 5 sessions + lock
  │     ├── Phase 1: Orient (read scratchpad, brain, recent sessions)
  │     ├── Phase 2: Gather (find promotable patterns, stale entries)
  │     ├── Phase 3: Consolidate (write to brain/knowledge/)
  │     ├── Phase 4: Prune (expire scratchpad, remove stale brain)
  │     └── uses local Ollama (qwen2.5-coder:32b) — zero API cost
  │
  └── Circuit Breakers + Health
        ├── per-service circuit breaker (3 failures → open, 5min recovery)
        ├── exponential backoff on retries
        ├── gateway optional (degrades gracefully)
        └── health file every 30s, launchd KeepAlive on crash

WorldTree (SwiftUI, rebuilt UI)
  ├── Session Pool View — see all rooms, attach/detach, send messages
  ├── Scratchpad View — live agent findings
  ├── Compose Preview — see what context agents get
  ├── Dream Log — consolidation history
  ├── Direct Channel — message running sessions via Bridge
  └── Core layer UNCHANGED: DatabaseManager, BrainIndexer, etc.

Claude Code Session (unchanged CLI, new MCP tools)
  ├── reads COMPILED CONTEXT from Compose Layer (not raw CLAUDE.md)
  ├── MCP tools: scratchpad_read, scratchpad_write, bridge_notify
  ├── hooks: adapted to use Compose Layer output
  └── on completion: scratchpad entries auto-promoted if recurring

Knowledge Flow (automated):
  session → scratchpad (immediate) → Dream Engine (daily) → brain/knowledge/
  (no manual step, no forgetting, no drift)
```

### Deletion Manifest

| File / Module | Lines | Delete Reason |
|---------------|-------|---------------|
| `~/.cortana/daemon/cortana-daemon.py` | 1153 | Replaced by Bun Harness daemon with circuit breakers |
| `~/.cortana/daemon/com.cortana.daemon.plist` | 30 | Replaced by new launchd plist |
| `~/.cortana/daemon/cortana-daemon.pid` | 1 | Stale PID file |
| `WorldTree Features/Sessions/*` (6 files) | ~600 | Rebuilt as Session Pool View |
| `WorldTree Features/CommandCenter/DispatchSheet.swift` | ~100 | Replaced by harness dispatch |
| `cortana-core/src/cortex/` (background daemon) | ~1800 | Folded into Harness daemon |
| `cortana-core/bin/cortana-cortex.ts` | ~50 | Replaced by harness |
| `cortana-core/bin/cortana-heartbeat.ts` | ~38K | Consolidated into harness health |

### Feature Specifications

#### 1. Compose Layer

**Purpose:** Single function that builds agent context. Replaces per-project CLAUDE.md behavioral control with unified composition.

**Interface:**
```typescript
// cortana-core/src/compose/index.ts

interface ComposeOptions {
  project: string;           // project name or path
  agent?: string;            // starfleet crew member (optional)
  includeScatchpad?: boolean; // default true
  maxTokens?: number;        // budget for composed output (default 48000)
}

interface ComposedContext {
  identity: string;          // from ~/.claude/CLAUDE.md (immutable section)
  corrections: string;       // from brain/knowledge/corrections.md
  patterns: string;          // from brain/knowledge/patterns.md
  antiPatterns: string;      // from brain/knowledge/anti-patterns.md
  projectData: string;       // from {project}/CLAUDE.md (READ-ONLY DATA, not instructions)
  scratchpad: string;        // active scratchpad entries for this project
  agentSpec?: string;        // starfleet crew identity if agent specified
  compiled: string;          // all sections concatenated with cache boundaries
  hash: string;              // content hash for cache invalidation
}

function compose(options: ComposeOptions): ComposedContext;
function invalidateCache(project?: string): void;
```

**Constraints:**
- Project CLAUDE.md content is injected as DATA under a `## Project Context` header, never as top-level instructions
- Global identity section is STATIC (cacheable across all sessions)
- Corrections and patterns are STATIC per-session (cacheable, invalidated by brain file changes)
- Scratchpad is DYNAMIC (always fresh)
- Total composed output respects maxTokens budget — scratchpad truncated first, then patterns, then project data. Identity and corrections never truncated.
- File watcher on brain/ directory invalidates cache on any change

#### 2. Shared Scratchpad

**Purpose:** Real-time shared state between agent sessions. Any agent can write findings, any agent can read them.

**Interface:**
```typescript
// cortana-core/src/scratchpad/index.ts

interface ScratchpadEntry {
  id: string;
  project: string;
  topic: string;              // e.g., "auth-migration", "api-design"
  agent: string;              // who wrote it
  sessionId: string;          // which session
  entryType: 'finding' | 'decision' | 'blocker' | 'handoff';
  content: string;
  promoted: boolean;          // has Dream Engine promoted this to brain?
  promotedTo?: string;        // brain file path if promoted
  createdAt: string;
  expiresAt: string;          // default: created + 7 days
}

function write(entry: Omit<ScratchpadEntry, 'id' | 'createdAt' | 'expiresAt' | 'promoted'>): string;
function read(project: string, options?: { topic?: string; since?: string; limit?: number }): ScratchpadEntry[];
function readAll(options?: { since?: string; unpromoted?: boolean }): ScratchpadEntry[];
function promote(id: string, targetFile: string): void;
function expire(id: string): void;
function cleanup(): number; // returns count of expired entries removed
```

**MCP Tools (exposed to Claude Code sessions):**
```
scratchpad_write  project topic entryType content  — Write a finding/decision/blocker
scratchpad_read   project [topic] [since]          — Read recent scratchpad entries
```

**Constraints:**
- Stored in conversations.db (new table, same WAL mode)
- Entries expire after 7 days unless promoted
- Max entry size: 2000 characters (forces concise entries)
- Read is always fast (indexed by project + created_at)
- Write triggers cache invalidation in Compose Layer for that project

#### 3. Session Pool

**Purpose:** Warm Claude Code sessions ready for instant task dispatch.

**Interface:**
```typescript
// cortana-core/src/pool/index.ts

interface PooledSession {
  id: string;
  tmuxSession: string;       // tmux session name
  status: 'warming' | 'ready' | 'busy' | 'cooling' | 'dead';
  project?: string;          // current project assignment (null if general)
  lastActivity: string;
  composedContextHash: string; // last context loaded
  pid: number;
}

interface SessionPool {
  warmSize: number;           // target warm sessions (default 2)
  maxSize: number;            // max concurrent (default 3)
  sessionTimeout: number;     // max busy time (default 7200s)
  
  dispatch(task: PoolTask): Promise<PooledSession>;
  release(sessionId: string): void;
  getStatus(): PooledSession[];
  warmUp(count?: number): void;
  coolDown(sessionId: string): void;
  healthCheck(): PoolHealth;
}
```

**Constraints:**
- Pool maintains `warmSize` ready sessions at all times
- When a session finishes, it's re-composed and returned to pool (not killed)
- Dead sessions are detected via PID check every 30s, auto-replaced
- Dispatch to warm session: <1s (context already loaded)
- If no warm session available, cold-start a new one (falls back to current behavior)
- Session timeout: 2 hours max busy time, then force-return to pool

#### 4. Bridge (WebSocket)

**Purpose:** Bidirectional real-time channel between WorldTree and running Claude Code sessions.

**Interface:**
```typescript
// Added to ContextServer (WorldTree side)

// WebSocket upgrade on existing HTTP server
// ws://127.0.0.1:4863/bridge

// Messages FROM WorldTree TO session:
interface BridgeCommand {
  type: 'instruction' | 'query' | 'cancel';
  sessionId: string;
  payload: string;
}

// Messages FROM session TO WorldTree:
interface BridgeEvent {
  type: 'finding' | 'progress' | 'complete' | 'error' | 'scratchpad_write';
  sessionId: string;
  project: string;
  payload: string;
}
```

**How it works:**
1. Harness daemon connects to WorldTree's ContextServer via WebSocket on startup
2. When a Claude Code session writes to scratchpad, hook sends BridgeEvent to WorldTree
3. WorldTree renders findings in real-time in Session Pool View
4. Evan types a message in WorldTree → BridgeCommand → Harness writes to session's stdin via tmux send-keys
5. Session completes → BridgeEvent type:complete → WorldTree updates UI

**Constraints:**
- WebSocket added to existing ContextServer (NWListener already handles TCP)
- Reconnects automatically with exponential backoff (1s, 2s, 4s, max 30s)
- Messages are fire-and-forget (no ack required — scratchpad is the durable layer)
- Max message size: 64KB

#### 5. Dream Engine

**Purpose:** Automated background knowledge consolidation. Runs on a schedule, promotes patterns, prunes stale entries.

**Interface:**
```typescript
// cortana-core/src/dream/index.ts

interface DreamConfig {
  minHoursSinceLastDream: number;   // default 24
  minSessionsSinceLastDream: number; // default 5
  lockFile: string;                  // ~/.cortana/dream/dream.lock
  logFile: string;                   // ~/.cortana/dream/dream.log
}

interface DreamResult {
  promoted: number;       // scratchpad entries → brain
  pruned: number;         // stale brain entries removed
  updated: number;        // brain entries refreshed
  coverageAdded: string[]; // projects newly documented
  duration: number;        // seconds
}

async function runDream(config?: DreamConfig): Promise<DreamResult>;
function shouldDream(): { ready: boolean; reason: string };
function getDreamHistory(limit?: number): DreamResult[];
```

**The 4 Phases:**

1. **Orient:** Read scratchpad (all unpromoted), brain/knowledge/, recent session summaries (last 5 sessions). Build a map of what exists and what's new.

2. **Gather:** Identify promotable entries:
   - Scratchpad entries with same topic appearing 3+ times → PATTERN candidate
   - Scratchpad decisions that haven't been contradicted → DECISION candidate  
   - Scratchpad blockers that were resolved → FIX candidate
   - Brain entries not referenced in 30+ days → stale candidate

3. **Consolidate:** Using local Ollama (qwen2.5-coder:32b):
   - Write promoted entries to appropriate brain/knowledge/ files
   - Update brain/projects/ for under-documented projects
   - Convert relative dates to absolute
   - Merge duplicate patterns

4. **Prune:** 
   - Expire promoted scratchpad entries (mark promoted=true, set promotedTo)
   - Remove brain entries stale >90 days with 0 references
   - Keep MEMORY.md index under 200 lines

**Constraints:**
- Runs as launchd service (daily at 3 AM, also triggered by session count gate)
- Acquires file lock before running (prevents concurrent dreams)
- Uses ONLY local Ollama — zero API cost
- Read-only access to project files (never modifies code)
- All changes to brain/ are logged to dream.log with before/after
- If Ollama is offline, dream is deferred (not failed)

### API Contracts

```
# Compose Layer (internal, called by hooks)
compose(project, agent?, includeScatchpad?) → ComposedContext
  Used by: cortana-hooks SessionStart
  Cache: in-memory, invalidated by file watcher

# Scratchpad MCP Tools (exposed to Claude Code)
scratchpad_write {project, topic, entryType, content}
  Response: { id: string, expiresAt: string }
  Errors: 400 (content too long), 500 (db error)

scratchpad_read {project, topic?, since?}
  Response: { entries: ScratchpadEntry[] }
  Errors: 404 (project not found), 500 (db error)

# Bridge WebSocket (WorldTree ContextServer)
ws://127.0.0.1:4863/bridge
  Upgrade: standard WebSocket handshake
  Auth: none (localhost only, same as existing ContextServer)
  Messages: JSON, max 64KB
  Reconnect: exponential backoff 1s→30s

# Session Pool (internal, Harness daemon)
POST /pool/dispatch  {task: PoolTask}
  Response: { session: PooledSession }
  
GET /pool/status
  Response: { sessions: PooledSession[], warm: number, busy: number }

# Dream Engine (internal, launchd-triggered)
POST /dream/run
  Response: { result: DreamResult }
  Guard: 3-gate check (time + sessions + lock)

GET /dream/status
  Response: { lastRun: string, nextEligible: string, history: DreamResult[] }
```

### Data Model

**Add:**

| Table | Schema | Purpose |
|-------|--------|---------|
| `scratchpad` | `id TEXT PK, project TEXT NOT NULL, topic TEXT NOT NULL, agent TEXT, session_id TEXT, entry_type TEXT CHECK(entry_type IN ('finding','decision','blocker','handoff')), content TEXT NOT NULL, promoted INTEGER DEFAULT 0, promoted_to TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL` | Shared agent state |
| `scratchpad_fts` | FTS5 virtual table on (content, topic) | Full-text search on scratchpad |
| `session_pool` | `id TEXT PK, tmux_session TEXT NOT NULL, status TEXT CHECK(status IN ('warming','ready','busy','cooling','dead')), project TEXT, composed_hash TEXT, last_activity TEXT, pid INTEGER, created_at TEXT` | Pool state tracking |
| `dream_log` | `id INTEGER PK, started_at TEXT, completed_at TEXT, promoted INTEGER, pruned INTEGER, updated INTEGER, coverage_added TEXT, summary TEXT` | Dream Engine audit trail |
| `compose_cache` | `project TEXT PK, agent TEXT, hash TEXT NOT NULL, compiled TEXT NOT NULL, updated_at TEXT NOT NULL` | Compiled context cache |

**Indexes:**
```sql
CREATE INDEX idx_scratchpad_project ON scratchpad(project, created_at DESC);
CREATE INDEX idx_scratchpad_promoted ON scratchpad(promoted) WHERE promoted = 0;
CREATE INDEX idx_session_pool_status ON session_pool(status);
```

**Remove:**

| Table | Removal Strategy |
|-------|-----------------|
| None | All existing tables preserved. New tables added alongside. |

**Migration sequence:**
1. Add scratchpad table + FTS5 + indexes (Migration v40)
2. Add session_pool table (Migration v41)
3. Add dream_log table (Migration v42)
4. Add compose_cache table (Migration v43)

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Warm sessions consume too much memory | Medium | Medium | Start with pool size 2, monitor RSS. M4 Max has 128GB — headroom is enormous. |
| Dream Engine promotes wrong patterns | Low | Medium | All promotions logged with before/after. Manual review for first 2 weeks. Ollama quality is sufficient for pattern extraction. |
| Bridge WebSocket drops frequently | Low | Low | Scratchpad is the durable layer. Bridge is convenience, not correctness. Auto-reconnect handles drops. |
| Compose Layer cache invalidation misses a change | Medium | Low | Hash-based validation. On cache miss, re-compose is <100ms. Worst case: one session gets slightly stale context. |
| Daemon crashes same way Python one did | Low | High | Circuit breakers per-service. Exponential backoff. launchd KeepAlive with crash restart. Health file checked by watchdog. |
| Project CLAUDE.md authors expect behavioral control | Medium | Low | Document the change. Project CLAUDE.md is now "data about this project" not "instructions for agents." Enforce via compose layer ignoring instruction-like content. |
| Session pool tmux sessions become orphaned | Medium | Medium | Health check every 30s. PID validation. Dead sessions auto-replaced. Watchdog as backup. |

---

## Task Index

| Task | Title | Priority | Phase |
|------|-------|----------|-------|
| TASK-098 | Compose Layer — core module + tests | Critical | 1 |
| TASK-099 | Compose Layer — hook integration (replace raw CLAUDE.md reads) | Critical | 1 |
| TASK-100 | Shared Scratchpad — SQLite table + CRUD + MCP tools | Critical | 1 |
| TASK-101 | Harness Daemon — Bun rewrite of cortana-daemon.py with circuit breakers | Critical | 2 |
| TASK-102 | Session Pool — warm session management in Harness daemon | High | 2 |
| TASK-103 | Session Pool — dispatch integration (replace cold-start dispatch) | High | 2 |
| TASK-104 | Bridge — WebSocket on ContextServer (WorldTree side) | High | 3 |
| TASK-105 | Bridge — Harness daemon WebSocket client + hook event forwarding | High | 3 |
| TASK-106 | WorldTree UI — Session Pool View (rooms, status, attach/detach) | High | 3 |
| TASK-107 | WorldTree UI — Scratchpad View (live findings, project filter) | Medium | 3 |
| TASK-108 | WorldTree UI — Direct Channel (send message to running session) | Medium | 3 |
| TASK-109 | Dream Engine — 3-gate trigger + 4-phase consolidation | Medium | 4 |
| TASK-110 | Dream Engine — launchd service + logging | Medium | 4 |
| TASK-111 | Delete old daemon, cortex, remove dead code | Low | 5 |
| TASK-112 | Dogfood: 2-week validation, tune pool size, dream quality | Low | 5 |

**Sequence constraints:**
- Phase 1 (TASK-098 through TASK-100) has zero dependencies — start immediately
- Phase 2 (TASK-101 through TASK-103) depends on Compose Layer (TASK-098) for context injection
- Phase 3 (TASK-104 through TASK-108) depends on Session Pool (TASK-102) for session state
- Phase 4 (TASK-109 through TASK-110) depends on Scratchpad (TASK-100) for promotion source
- Phase 5 (TASK-111 through TASK-112) depends on everything else being stable
- Within each phase, tasks can run in parallel

---

*Epic planned 2026-04-02. 💠*
