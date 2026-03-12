# EPIC: Agent Orchestration Dashboard

**Objective**: Transform World Tree's Command Center from a passive activity log into an active mission control for multi-agent development — real-time status, intelligent routing of attention, and structured review of agent output.

**Success Criteria**:
1. Single-glance awareness of all active agents/sessions within 2 seconds of opening Command Center
2. Never miss a permission prompt or stuck agent — attention routing surfaces critical items within 10 seconds
3. Review agent output through PR-style diffs without switching to terminal
4. Session health visible at a glance — red/yellow/green, no mental math required
5. Token spend visible per session, per project, per day with burn rate trends
6. File conflicts between agents detected before they become merge conflicts
7. Event-triggered agent launches reduce manual dispatch by 50%+

**Architecture Principle**: cortana-core hooks WRITE data to SQLite. World Tree READS and displays. No new write paths from World Tree except UI state persistence.

---

## Sprint Breakdown

### Sprint 1 — Situational Awareness (Tier 1)
TASK-134 through TASK-142. Core visibility: know what every agent is doing right now.

### Sprint 2 — Intelligence Layer (Tier 2, part 1)
TASK-143 through TASK-149. Health scoring, token dashboard, conflict detection.

### Sprint 3 — Automation & Polish (Tier 2 part 2 + Tier 3)
TASK-150 through TASK-156. Event-triggered launches, terminal focus, memory viz, persistent UI.

---

## Data Flow Diagram

```
WRITERS (cortana-core / TypeScript)                  READERS (World Tree / Swift)
─────────────────────────────────────                ────────────────────────────

Hooks: PostToolUse                                   AgentStatusStore
  → session_state (goal, phase, files,               ← ValueObservation on agent_sessions
     errors, commands)                                ← session_state joins
  → canvas_token_usage (per-turn tokens)             ← Polls tmux for process state

Hooks: SessionStart/End                              AttentionRouter
  → agent_sessions (new table — agent                ← ValueObservation on agent_sessions
     lifecycle events)                                ← Filters: stuck, permission, complete,
  → session_state updates                               context_low

Hooks: Stop                                          DiffReviewStore
  → agent_sessions.completed_at                      ← Reads git diff per session worktree
  → agent_sessions.files_changed (JSON)              ← On-demand when user opens review
  → agent_sessions.exit_reason
                                                     SessionHealthCalculator
cortana-dispatch:                                    ← Combines: token burn rate + error count
  → agent_sessions (dispatch lifecycle)                + retry count + files touched
  → dispatch_queue (existing)                        ← Emits red/yellow/green per session

Heartbeat:                                           TokenDashboardStore
  → heartbeat_runs (existing)                        ← canvas_token_usage aggregations
  → governance_journal (existing)                    ← canvas_project_metrics
  → dispatch_queue (existing)                        ← Burn rate = tokens/minute over window

NEW: File touch tracking                             ConflictDetector
  → agent_file_touches (new table —                  ← Cross-join agent_file_touches
     agent + file + timestamp)                       ← Alert when 2+ agents touch same file

NEW: Attention events                                EventRuleEngine
  → agent_attention_events (new table —              ← Reads event_trigger_rules (user-defined)
     type, severity, session_id, message)            ← Matches heartbeat signals to rules
                                                     ← Dispatches via existing ClaudeBridge
```

---

## New SQLite Tables

All tables in `conversations.db` (World Tree's shared database).

### `agent_sessions` — Unified agent lifecycle tracking
```sql
CREATE TABLE agent_sessions (
    id TEXT PRIMARY KEY,                    -- session/dispatch ID
    agent_name TEXT,                        -- 'geordi', 'data', etc. or NULL for interactive
    project TEXT NOT NULL,
    working_directory TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'interactive',  -- 'interactive', 'dispatch', 'heartbeat', 'event_rule'

    -- Lifecycle
    status TEXT NOT NULL DEFAULT 'starting'
        CHECK(status IN ('starting','thinking','writing','tool_use','waiting','stuck','idle','completed','failed','interrupted')),
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP,
    last_activity_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    -- Current work
    current_task TEXT,                      -- from session_state.goal or dispatch prompt
    current_file TEXT,                      -- last file being edited
    current_tool TEXT,                      -- active tool name if in tool_use

    -- Health signals
    error_count INTEGER DEFAULT 0,
    retry_count INTEGER DEFAULT 0,
    consecutive_errors INTEGER DEFAULT 0,   -- resets on success

    -- Token tracking
    tokens_in INTEGER DEFAULT 0,
    tokens_out INTEGER DEFAULT 0,
    context_used INTEGER DEFAULT 0,         -- estimated context window usage
    context_max INTEGER DEFAULT 200000,     -- model context limit

    -- Output
    files_changed TEXT DEFAULT '[]',        -- JSON array of file paths
    exit_reason TEXT,                       -- 'success', 'error', 'cancelled', 'context_exhausted', 'timeout'

    -- Dispatch linkage
    dispatch_id TEXT,                       -- FK to canvas_dispatches if from dispatch

    FOREIGN KEY (dispatch_id) REFERENCES canvas_dispatches(id)
);
CREATE INDEX idx_agent_sessions_status ON agent_sessions(status);
CREATE INDEX idx_agent_sessions_project ON agent_sessions(project);
CREATE INDEX idx_agent_sessions_active ON agent_sessions(status)
    WHERE status NOT IN ('completed', 'failed', 'interrupted');
```

### `agent_file_touches` — Cross-agent file conflict detection
```sql
CREATE TABLE agent_file_touches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    agent_name TEXT,
    file_path TEXT NOT NULL,
    project TEXT NOT NULL,
    action TEXT NOT NULL DEFAULT 'edit',    -- 'edit', 'create', 'delete', 'read'
    touched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (session_id) REFERENCES agent_sessions(id)
);
CREATE INDEX idx_file_touches_file ON agent_file_touches(file_path);
CREATE INDEX idx_file_touches_session ON agent_file_touches(session_id);
CREATE INDEX idx_file_touches_recent ON agent_file_touches(touched_at);
```

### `agent_attention_events` — Priority-ranked notifications
```sql
CREATE TABLE agent_attention_events (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    type TEXT NOT NULL
        CHECK(type IN ('permission_needed','stuck','error_loop','completed','context_low','conflict','review_ready')),
    severity TEXT NOT NULL DEFAULT 'info'
        CHECK(severity IN ('critical','warning','info')),
    message TEXT NOT NULL,
    metadata TEXT,                          -- JSON: file paths, error details, etc.
    acknowledged INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    acknowledged_at TIMESTAMP,

    FOREIGN KEY (session_id) REFERENCES agent_sessions(id)
);
CREATE INDEX idx_attention_unack ON agent_attention_events(acknowledged, severity);
CREATE INDEX idx_attention_session ON agent_attention_events(session_id);
```

### `event_trigger_rules` — User-defined automation rules
```sql
CREATE TABLE event_trigger_rules (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    enabled INTEGER DEFAULT 1,
    trigger_type TEXT NOT NULL,             -- 'heartbeat_signal', 'error_count', 'build_failure', 'session_complete'
    trigger_config TEXT NOT NULL,           -- JSON: { "signal": "app_crash", "threshold": 3 }
    action_type TEXT NOT NULL,              -- 'dispatch_agent', 'notify', 'run_command'
    action_config TEXT NOT NULL,            -- JSON: { "agent": "geordi", "project": "WorldTree", "prompt_template": "..." }
    last_triggered_at TIMESTAMP,
    trigger_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### `ui_state` — Persistent UI preferences
```sql
CREATE TABLE ui_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

## Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| WAL checkpoint breaks GRDB observation | App hangs, stale data | Medium | NEVER use TRUNCATE checkpoint in World Tree. Migrations already fixed to use PASSIVE. |
| agent_sessions table gets stale (hook fails to update) | Dashboard shows wrong status | High | Watchdog timer: if last_activity_at > 5min and status is active, mark as 'stuck'. DispatchSupervisor pattern already exists. |
| High-frequency file touch writes slow DB | UI stuttering | Medium | Batch inserts (accumulate for 5s, write once). Delete touches older than 24h on startup. |
| Git diff for large repos blocks main thread | App freeze | High | All git operations on background actor. Timeout after 10s. Cache diffs. |
| Event rules dispatch too aggressively | Token burn, noise | Medium | Cooldown per rule (minimum 30min between triggers). Max 3 auto-dispatches per hour. Daily budget cap. |
| Two agents touch same file despite warning | Merge conflicts | Low (detection is the feature) | Detection is best-effort. Show warning prominently but don't block — agents may legitimately edit different sections. |
| @MainActor isolation violations in new stores | Crash | Medium | Follow HeartbeatStore pattern exactly: @MainActor class, async fetch on GRDB reader queue, assign on main. |
| Migration fails on existing DB | App won't launch | Low | IF NOT EXISTS on all CREATE TABLE. Migrations are additive only. Pre-migration backup (existing pattern). |

---

## File Organization

```
Sources/Core/Database/
    AgentStatusStore.swift          -- TASK-135: Reactive agent session observation
    AttentionStore.swift            -- TASK-139: Attention event queries
    ConflictDetector.swift          -- TASK-148: File touch cross-join queries
    EventRuleStore.swift            -- TASK-150: Rule CRUD + matching
    UIStateStore.swift              -- TASK-155: Key-value persistence

Sources/Core/Models/
    AgentSession.swift              -- TASK-134: GRDB model + health scoring
    AttentionEvent.swift            -- TASK-139: Attention event model
    SessionHealth.swift             -- TASK-143: Health score calculation
    EventRule.swift                 -- TASK-150: Rule model

Sources/Features/CommandCenter/
    AgentStatusBoard.swift          -- TASK-136: Main status board view
    AgentStatusCard.swift           -- TASK-137: Individual agent card
    AttentionPanel.swift            -- TASK-140: Priority notification panel
    DiffReviewView.swift            -- TASK-141: PR-style diff viewer
    DiffReviewSheet.swift           -- TASK-142: Full-screen diff sheet
    SessionHealthBadge.swift        -- TASK-144: Red/yellow/green indicator
    TokenDashboardView.swift        -- TASK-146: Token/cost dashboard
    ConflictWarningBanner.swift     -- TASK-149: File conflict UI
    EventRulesSheet.swift           -- TASK-151: Rule editor

Sources/Features/Settings/
    EventRuleSettingsView.swift     -- TASK-151: Settings integration
```

*"I know exactly where every agent is, what they're doing, and whether they need me. That's not micromanagement — that's command."*
