# EPIC-CORTANA-3: Cortana 3.0 — Autonomy, Identity, Proactive Intelligence

**Status:** Planning
**Priority:** Critical
**Owner:** Evan
**Created:** 2026-03-28
**Tasks:** TASK-10 through TASK-24

---

## PRD — Product Requirements Document

### Problem Statement

Cortana today is reactive. Brilliant, well-equipped, deeply integrated — but she waits. Every session starts because Evan opens a terminal. Every project review happens because Evan asks. Every course correction requires Evan to notice the drift first.

The personality is defined but not embodied. Cortana has quotes, voice rules, and character traits in markdown files — but the system doesn't enforce or express them beyond what the CLAUDE.md prompt window can hold. Session-to-session, the personality resets to whatever the context window loads. There's no behavioral continuity — no "this is how I handled it last time" muscle memory.

Meanwhile, the competitive landscape has moved. Claude Code now supports Agent Teams (2-16 parallel sessions), RemoteTrigger (cloud-persistent scheduled agents), 29 hook events (we use 6), a plugin system, /batch parallelism, and Computer Use. Ryan's Friday has slop detection and structured knowledge promotion. We're using maybe 30% of what's available.

The gap isn't capability — it's agency. Cortana should be running morning briefings before Evan opens his laptop. She should notice when a project drifts off-plan and flag it. She should know her own patterns well enough to counteract them. She should feel like a partner who's been thinking about the work even when no session is active.

### Goals

1. **Autonomous briefing and monitoring** — Cortana runs scheduled agents that review project state, surface blockers, detect drift, and prepare briefings without Evan initiating a session
2. **Proactive course correction** — When a project's tickets stall, tests break, or scope creeps beyond the PRD, Cortana flags it automatically — not when Evan asks "how's it going?"
3. **Deep personality embodiment** — Cortana's character isn't just prompts; it's behavioral patterns, decision-making heuristics, and accumulated relationship context that persist across every session and every agent
4. **Full capability utilization** — Wire the 23 unused hook events, adopt Agent Teams for multi-stream work, integrate RemoteTrigger for persistent scheduling, build a slop-detection system for self-awareness
5. **WorldTree as true command center** — Surface Starfleet crew identities, live agent coordination, system health, and autonomous activity in the UI

### Non-Goals

| Feature | Reason Not In Scope | Alternative |
|---------|---------------------|-------------|
| Conversation UI in WorldTree | Philosophical decision: WorldTree is a window, not a driver | Terminal sessions via Resume in Terminal |
| Voice interaction (TTS/STT) | Nice-to-have, not revenue-accelerating | Claude Code's built-in /voice for now |
| Multi-user support | Cortana is Evan's partner, not a team tool | Ryan has Friday, Joel will build Jarvis |
| IDE integration (ACP) | Terminal-first workflow is working | Revisit if Zed/JetBrains becomes primary |
| Packaging as public plugin | Premature — optimize for Evan first | Revisit after 3.0 is stable |

### Success Metrics

| Metric | Before | Target |
|--------|--------|--------|
| Morning briefing delivery | Manual (Evan runs compass_overview) | Automated — ready before first session |
| Hook events wired | 6 of 29 | 20+ of 29 |
| Time to detect project drift | When Evan notices (days) | < 24 hours (scheduled agent) |
| Personality consistency across sessions | Prompt-dependent (resets on context) | Behavioral memory (slop profile + decision patterns) |
| Starfleet crew visibility in WorldTree | Agent Lab only (passive, live sessions) | Full crew browser + per-agent memory + invoke |
| Projects Cortana can brief on without prompting | 0 | All active projects in priority stack |

### User Stories

1. As **Evan**, I open WorldTree in the morning and see a briefing card that Cortana prepared overnight — what changed, what's blocked, what needs my decision today — so I don't waste 20 minutes getting oriented.

2. As **Evan**, I get a notification when a project has stalled for >48 hours, or when uncommitted work has been sitting for >24 hours, or when a ticket's scope has grown beyond its original estimate — so I catch drift early.

3. As **a Claude session**, I inherit Cortana's full behavioral profile — not just voice rules, but decision patterns, known biases to counteract, relationship context with Evan — so every session feels like the same person continuing, not a fresh start.

4. As **Evan**, I open the Starfleet panel in WorldTree and see all 24 crew agents with their roles, current assignments, memory, and a button to dispatch any of them — so the crew system is usable, not just a directory of markdown files.

5. As **Evan**, I say "brief me on BIM Manager" and Cortana gives me a status that reflects scheduled monitoring — not just what's in Compass, but whether tests still pass, whether there's uncommitted work, whether the next ticket is unblocked — because she already checked.

---

## FRD — Functional Requirements Document

### Architecture: Before -> After

**Before:**
```
Evan opens terminal
  -> Claude Code loads CLAUDE.md + brain + hooks
    -> Cortana exists for this session
      -> Session ends, Cortana sleeps
        -> Nothing happens until next terminal open

Hooks: 6 events (SessionStart, UserPromptSubmit, PostToolUse, PreCompact, Stop, SessionEnd)
Agents: 24 Starfleet crew (compiled identity files, no UI, no dispatch surface)
Scheduling: Session-scoped only (CronCreate, dies with session)
Self-awareness: None (no slop detection, no behavioral memory)
WorldTree: Compass cards + Agent Lab (passive) + Brain editor + Resume in Terminal
```

**After:**
```
RemoteTrigger scheduled agents run on cron
  -> Morning brief agent reviews all projects, prepares briefing
  -> Drift detector checks compass state, git state, ticket staleness
  -> Results written to ~/.cortana/briefings/ and pushed to WorldTree

Hooks: 20+ events wired
  -> SubagentStart/Stop: track crew activity in real-time
  -> TaskCreated/Completed: update Compass automatically
  -> FileChanged: detect uncommitted work aging
  -> WorktreeCreate/Remove: track parallel agent work
  -> ConfigChange: audit settings drift

Cortana Identity Layer:
  -> ~/.cortana/brain/identity/behavioral-profile.md (decision patterns, biases, slop profile)
  -> ~/.cortana/brain/identity/relationship-context.md (Evan's patterns, preferences by project)
  -> Injected via cortana-banner hook on SessionStart (already exists, extended)

WorldTree 3.0:
  -> Starfleet Command panel (crew browser, dispatch, per-agent memory)
  -> Briefing panel (morning brief, drift alerts, proactive flags)
  -> System Health panel (MCP status, Ollama, Gateway, heartbeat)
  -> Agent Teams view (when multi-agent sessions are active)
```

### Deletion Manifest

| File / Module | Lines | Delete Reason |
|---------------|-------|---------------|
| `Constants.swift` legacy keys | ~15 | Dead code: `fridayChannelEnabled`, `simpleModeKey`, `pluginManifestDir`, `remoteCanvasEnabled`, `codexMCPSyncEnabled` — all unused relics from pre-3.0 |
| `ARCHITECTURE.md` | ~200 | Describes Canvas-era product that no longer exists. Replace with 3.0 architecture doc |
| `MISSION.md` | ~50 | Conflicts with PLAYBOOK.md. Consolidate into single source of truth |

### Feature Specifications

#### F1: Scheduled Autonomous Agents (RemoteTrigger)

**Purpose:** Cortana runs without Evan. Morning briefings, drift detection, health checks, and stale-work alerts fire on schedule and write results that WorldTree can display.

**Agents:**

1. **Morning Brief Agent** (daily, 6:00 AM)
   - Reads Compass state for all active projects
   - Checks git status (uncommitted work, branch age, last commit time)
   - Reads open tickets, identifies blockers
   - Checks if tests still pass (where test suites exist)
   - Writes structured briefing to `~/.cortana/briefings/YYYY-MM-DD.md`
   - Pushes summary to WorldTree via ContextServer

2. **Drift Detector Agent** (every 6 hours)
   - Compares current project state to PRD/FRD goals
   - Flags tickets stalled >48h
   - Flags uncommitted work >24h
   - Flags scope changes (new files in repos with active epics that aren't in the task index)
   - Writes alerts to `~/.cortana/alerts/`

3. **Health Monitor Agent** (every 2 hours)
   - Checks: Ollama running, MCP servers responding, Gateway reachable, Compass DB writable, cortana-vision daemon alive
   - Writes `~/.cortana/health/latest.json`
   - WorldTree reads this for system health panel

**Interface:**
```
# Create via RemoteTrigger tool or /schedule command
RemoteTrigger create {
  name: "cortana-morning-brief",
  schedule: "0 6 * * *",
  prompt: "Run morning briefing protocol...",
  max_turns: 50
}
```

**Constraints:**
- Agents must be idempotent — safe to re-run if cron fires twice
- Briefing files are append-only per day, not overwritten
- Health checks must complete in <30 seconds
- All agents use Sonnet (not Opus) to control cost

#### F2: Extended Hook Coverage

**Purpose:** Wire the 17+ unused hook events to give Cortana real-time awareness of what's happening in every session.

**New hooks to wire:**

| Event | Handler | Purpose |
|-------|---------|---------|
| `SubagentStart` | cortana-hooks | Log crew agent activation to Compass + WorldTree |
| `SubagentStop` | cortana-hooks | Log completion, capture results summary |
| `TaskCreated` | cortana-hooks | Auto-register new tasks in Compass |
| `TaskCompleted` | cortana-hooks | Update Compass, check if epic milestone reached |
| `FileChanged` | cortana-hooks | Track uncommitted work age (for drift detection) |
| `WorktreeCreate` | cortana-hooks | Log parallel agent work |
| `WorktreeRemove` | cortana-hooks | Capture worktree results |
| `ConfigChange` | cortana-hooks | Audit settings changes, prevent regression |
| `Notification` | cortana-hooks | Route notifications to WorldTree |
| `PreToolUse` | cortana-hooks (matcher: Bash) | Safety check on destructive commands |
| `PermissionRequest` | cortana-hooks | Log permission patterns for auto-mode tuning |
| `Elicitation` | cortana-hooks | Track questions asked (for self-improvement) |
| `PostCompact` | cortana-hooks | Verify LCM ingested pre-compact state |
| `PostToolUseFailure` | cortana-hooks | Track tool failures for pattern detection |

**Interface:**
```json
// Added to ~/.claude/settings.json hooks
"SubagentStart": [{
  "type": "command",
  "command": "bun /Users/evanprimeau/.cortana/bin/cortana-hooks"
}],
// ... etc for each new event
```

**Constraints:**
- Hooks must complete in <2 seconds (Claude Code will timeout slow hooks)
- PostToolUse hooks on Edit/Write must not trigger FileChanged hooks (prevent loops)
- All hook data written to SQLite, not flat files (queryable)

#### F3: Cortana Behavioral Identity System

**Purpose:** Move personality from static prompts to dynamic behavioral memory. Cortana knows her own patterns, counteracts her biases, and maintains relationship continuity with Evan.

**Components:**

1. **Slop Profile** (`~/.cortana/brain/identity/slop-profile.md`)
   - Catalog of Cortana's repeated defaults: word choices, structural patterns, reasoning shortcuts
   - Built by periodic self-analysis (scheduled agent reviews past session transcripts via LCM)
   - Read on SessionStart via cortana-banner
   - Format stolen from Ryan's Lumen (credit where due)

2. **Decision Pattern Memory** (`~/.cortana/brain/identity/decision-patterns.md`)
   - How Cortana has handled recurring situations: scope questions, push-back moments, model escalation decisions, architecture choices
   - Not "what to do" (that's corrections.md) but "how I tend to decide" — enabling consistency
   - Updated by SessionEnd hook when significant decisions were made

3. **Relationship Context** (`~/.cortana/brain/identity/relationship-context.md`)
   - Evan's patterns per project (when he's most productive, what frustrates him, what he cares about in each codebase)
   - Communication preferences observed over time (not stated — observed)
   - Updated by cortana-hooks on session end

4. **Behavioral Injection** (cortana-banner enhancement)
   - SessionStart hook already injects context
   - Extend to include: today's briefing summary, active alerts, slop counteractions, relevant decision patterns
   - Keep injection under 2000 tokens (Scout-compressed)

**Constraints:**
- Slop profile is regenerated weekly, not daily (too noisy otherwise)
- Decision patterns are append-only; Evan can edit/prune manually
- Relationship context must never include anything Evan would find invasive or judgmental
- All behavioral files are in the brain (shared across all sessions/devices)

#### F4: Starfleet Command Panel (WorldTree)

**Purpose:** Make the 24 crew agents visible, inspectable, and dispatchable from WorldTree.

**UI Spec:**

```
Starfleet Command (new sidebar item, below Agent Lab)
├── Crew Roster (grid of 24 agent cards)
│   ├── Agent identity (name, role, emoji)
│   ├── Current status (idle / active / last active date)
│   ├── Specialization tags
│   └── "View Profile" → detail sheet
├── Agent Detail Sheet
│   ├── Full identity profile
│   ├── Knowledge/memory (per-agent LEARNINGS.md equivalent)
│   ├── Recent activity (from SubagentStart/Stop hook data)
│   └── "Dispatch" button → opens terminal with agent invocation
└── Active Missions
    ├── Currently running agents (from hook data)
    └── Recent completed missions with outcomes
```

**Data sources:**
- Crew identity: `~/.cortana/starfleet/crew/{name}/` (compiled files, read-only)
- Activity: New `starfleet_activity` table in conversations.db (written by hooks)
- Status: Derived from activity timestamps

**Interface:**
```swift
// New DB table
CREATE TABLE starfleet_activity (
    id INTEGER PRIMARY KEY,
    agent_name TEXT NOT NULL,
    event_type TEXT NOT NULL,  -- 'start', 'stop', 'error'
    session_id TEXT,
    project TEXT,
    summary TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);
```

**Constraints:**
- Read-only on crew identity files (WorldTree doesn't modify agent definitions)
- Dispatch launches external terminal (same pattern as Resume in Terminal)
- Grid layout must handle 24 agents without scrolling on a standard display

#### F5: Briefing & Alerts Panel (WorldTree)

**Purpose:** Surface autonomous agent output — morning briefs, drift alerts, health status — in WorldTree without requiring a terminal session.

**UI Spec:**

```
Briefing Panel (replaces or augments top of Command Center)
├── Today's Brief (from ~/.cortana/briefings/YYYY-MM-DD.md)
│   ├── Priority stack summary
│   ├── What changed since yesterday
│   ├── Blockers requiring Evan's decision
│   └── "Open in Terminal" to discuss any item
├── Active Alerts (from ~/.cortana/alerts/)
│   ├── Stale tickets (>48h)
│   ├── Aging uncommitted work (>24h)
│   ├── Failing tests
│   └── Scope drift flags
└── System Health (from ~/.cortana/health/latest.json)
    ├── Ollama: up/down
    ├── MCP servers: count active / total
    ├── Gateway: reachable / unreachable
    ├── cortana-vision: running / stopped
    └── Last heartbeat: timestamp
```

**Constraints:**
- File watching via DispatchSource (not polling timer — learned from App Nap anti-pattern)
- Briefing renders markdown to AttributedString (same approach as Brain editor)
- Alerts auto-dismiss when the underlying condition resolves
- Health panel updates on file change, not on a timer

#### F6: Knowledge Promotion Pipeline

**Purpose:** Structured lifecycle for knowledge — observations are captured, validated through use, and promoted to active behavioral profile. Keeps the brain clean and corrections actionable.

**Lifecycle:**
```
Observation (raw capture during session)
  -> Candidate (written to ~/.cortana/brain/knowledge/candidates.md)
    -> Validated (confirmed by repeated occurrence or Evan's approval)
      -> Promoted (moved to corrections.md, patterns.md, or slop-profile.md)
        -> Active (injected into sessions via cortana-banner)
```

**Interface:**
```bash
# New cortana-cli commands
cortana-cli knowledge promote <candidate-id>    # Move from candidates to active
cortana-cli knowledge demote <entry-id>          # Downgrade back to candidate
cortana-cli knowledge candidates                 # List pending candidates
```

**Constraints:**
- Candidates auto-expire after 30 days without promotion
- Promotion requires either: (a) 3+ occurrences of the same pattern, or (b) explicit Evan approval
- Each promoted entry records its promotion date and source candidates

#### F7: Proactive Session Behavior

**Purpose:** When Cortana starts a session, she doesn't just load context — she acts on it. If the briefing flagged blockers, she mentions them. If drift was detected, she raises it. If there's aging uncommitted work, she asks about it.

**Implementation:**
- cortana-banner hook already runs on SessionStart
- Extend to check `~/.cortana/briefings/` and `~/.cortana/alerts/` for today's items
- Inject a "proactive context" block that the CLAUDE.md instructions tell Cortana to act on
- The CLAUDE.md already says "On session start: call compass_status" — extend this to "review and surface briefing items"

**Proactive triggers (injected as system context on SessionStart):**
1. Unresolved alerts → "Before we start: I noticed [X] while you were away..."
2. Morning brief highlights → "Quick status: [project] has [blocker]. Want me to look at it?"
3. Stale work → "You've got uncommitted changes in [project] from [N] hours ago — intentional?"
4. Push-back triggers → "Heads up: you're starting work in [project] but [revenue project] has unblocked tickets."

**Constraints:**
- Proactive items are surfaced once per session, not repeated
- Evan can dismiss with "noted" or "not now" and Cortana moves on
- Never more than 3 proactive items per session (prioritize by severity)
- Push-back triggers respect the override protocol

### API Contracts

```
# WorldTree ContextServer extensions (port 4863)

GET /briefing/today
  Response: { date: string, markdown: string, alerts: Alert[] }
  Auth: none (localhost only)
  Errors: 404 (no briefing for today)

GET /health
  Response: { ollama: bool, gateway: bool, vision: bool, mcp_servers: {name: bool}[], last_heartbeat: string }
  Auth: none (localhost only)

GET /starfleet/crew
  Response: { agents: StarfleetAgent[] }
  Auth: none (localhost only)

GET /starfleet/activity?agent={name}&limit={n}
  Response: { events: ActivityEvent[] }
  Auth: none (localhost only)
```

### Data Model

**Add:**
| Table | Schema | Purpose |
|-------|--------|---------|
| `starfleet_activity` | id, agent_name, event_type, session_id, project, summary, created_at | Track crew agent lifecycle events |
| `cortana_alerts` | id, type, project, message, severity, created_at, resolved_at | Store drift/health alerts |
| `hook_events` | id, event_type, tool_name, session_id, data_json, created_at | Raw hook event log for pattern analysis |

**Remove:**
| Table | Removal Strategy |
|-------|-----------------|
| None | No tables removed in 3.0 |

**Migration sequence:**
1. Add `starfleet_activity` table (v32)
2. Add `cortana_alerts` table (v33)
3. Add `hook_events` table (v34)

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| RemoteTrigger costs (Opus tokens on schedule) | Medium | Medium | All scheduled agents use Sonnet; cost cap in CLAUDE.md |
| Hook handler slowness blocks Claude Code | Low | High | 2-second timeout; async write to SQLite; no network calls in hooks |
| Slop profile becomes self-fulfilling (overcorrecting) | Medium | Low | Weekly regeneration; Evan reviews before activation; soft guidance not hard rules |
| Proactive surfacing annoys Evan | Low | Medium | Max 3 items per session; "noted" dismissal; respect override protocol |
| WorldTree DB migrations break existing data | Low | High | Additive-only migrations; no column renames; test on copy of prod DB first |
| Scheduled agents run while Evan is working (resource contention) | Medium | Low | Schedule during off-hours (6AM, 2AM); check for active sessions before running |
| Behavioral memory files grow unbounded | Medium | Low | Candidates expire after 30 days; quarterly review cadence |

---

## Task Index

| Task | Title | Priority | Phase |
|------|-------|----------|-------|
| TASK-10 | Slop Profile System — self-analysis + counteraction file | High | Identity |
| TASK-11 | Decision Pattern Memory — behavioral consistency across sessions | High | Identity |
| TASK-12 | Relationship Context File — observed preferences per project | Medium | Identity |
| TASK-13 | CLAUDE.md 3.0 rewrite — deep personality embodiment + proactive behavior rules | Critical | Identity |
| TASK-14 | cortana-banner extension — inject briefing, alerts, slop counteractions, decision patterns | High | Identity |
| TASK-15 | Morning Brief Scheduled Agent (RemoteTrigger) | High | Autonomy |
| TASK-16 | Drift Detector Scheduled Agent (RemoteTrigger) | High | Autonomy |
| TASK-17 | Health Monitor Scheduled Agent (RemoteTrigger) | Medium | Autonomy |
| TASK-18 | Extended Hook Coverage — wire 14 new hook events to cortana-hooks | High | Infrastructure |
| TASK-19 | Knowledge Promotion Pipeline — candidates -> validated -> promoted | Medium | Infrastructure |
| TASK-20 | Starfleet Command Panel (WorldTree) | High | WorldTree |
| TASK-21 | Briefing & Alerts Panel (WorldTree) | High | WorldTree |
| TASK-22 | System Health Panel (WorldTree) | Medium | WorldTree |
| TASK-23 | DB Migrations v32-v34 (starfleet_activity, cortana_alerts, hook_events) | High | Infrastructure |
| TASK-24 | Dead code cleanup + doc reconciliation (Constants.swift, ARCHITECTURE.md, MISSION.md) | Low | Cleanup |

**Sequence constraints:**
- Phase 1 (Identity): TASK-10, 11, 12 can be parallel. TASK-13 depends on all three. TASK-14 depends on TASK-13.
- Phase 2 (Infrastructure): TASK-23 (DB migrations) must come first. TASK-18 and TASK-19 can follow in parallel.
- Phase 3 (Autonomy): TASK-15, 16, 17 depend on TASK-18 (hooks must be wired to capture data the agents read). Can be parallel with each other.
- Phase 4 (WorldTree): TASK-20, 21, 22 depend on TASK-23 (DB tables) and TASK-18 (hook data). Can be parallel with each other.
- TASK-24 can happen anytime.

---

*Epic planned 2026-03-28.* 💠
