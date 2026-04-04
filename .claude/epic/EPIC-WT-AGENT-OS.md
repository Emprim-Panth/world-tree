# EPIC-WT-AGENT-OS: Agent Operating System — Isolation, Hierarchy, and Canonical Knowledge

**Status:** Planning
**Priority:** Critical (prerequisite for all multi-agent work)
**Owner:** Evan
**Created:** 2026-04-02
**Depends on:** EPIC-CORTANA-HARNESS (warm pool, daemon, bridge DB)
**Authority document:** `~/.cortana/CONSTITUTION.md` — the single source of truth this epic implements

---

## PRD — Product Requirements Document

### Problem Statement

The harness gives us warm sessions and bidirectional communication. But sessions are still ungoverned — any agent can write anywhere, read anything, spawn anything, and ignore the crew hierarchy. The Starfleet crew profiles exist but they are **suggestions**, not enforcement. Knowledge lands wherever a session happened to be running. Three sessions crashing today exposed the deeper failure: no order, no authority, no canonical location. We get what we inspect, not what we intend.

**The five structural gaps this epic closes:**

1. **No namespace isolation.** A worker session running in BIM Manager can write corrections to the World Tree knowledge base. There is no enforcement preventing this.

2. **No hardwired hierarchy.** Picard's crew structure exists in compiled profiles, but the harness doesn't know who is who. Any session can claim any role. Workers can spawn Leads. Leads can bypass CTO review. The org chart is decorative.

3. **No canonical brain.** Knowledge lives in `~/.cortana/brain/*.md`, `~/.cortana/starfleet/crew/{agent}/memory/`, `~/.cortana/starfleet/crew/{agent}/knowledge/`, `~/.cortana/claude-memory/conversations.db`, `~/.cortana/compass.db`, and scattered project CLAUDE.md files. When a session ends and something was learned, nobody agreed on where it goes.

4. **Scratchpad is inert.** The scratchpad table exists in the DB (v40 migration). The dream engine is planned (EPIC-CORTANA-HARNESS). But scratchpad entries have no namespace, no crew attribution, no routing rules. Dream state doesn't know which entries belong to which project or who wrote them.

5. **New work has no designated home.** When a session makes a discovery that doesn't fit an existing project (e.g., a general engineering pattern, a job acquisition strategy, a tooling decision), there is no defined landing zone. Agents create new files, new directories, new ad-hoc structures. Entropy compounds.

### Goals

1. **One canonical DB.** All knowledge, corrections, decisions, patterns, scratchpad entries, and crew memories live in `~/.cortana/world-tree.db`. No competing files. No parallel structures.

2. **Locked namespaces.** Pre-defined knowledge namespaces. Agents write only to their assigned namespace. No agent creates new namespaces. New-situation knowledge routes to the closest pre-defined category.

3. **Hardwired crew hierarchy.** The harness assigns every session a crew role at spawn time. The system prompt is injected by the harness — the agent cannot override its own role. Capabilities (what a session can read, write, spawn, approve) are determined by role, not by the agent's self-assessment.

4. **Scratchpad as working memory with namespace.** Every scratchpad write is tagged: crew member, namespace, session ID, timestamp. The dream engine promotes namespace-tagged entries to the correct knowledge partition. Agents learn during work; the dream cycle consolidates overnight.

5. **Dream state teaches the crew.** During dream cycles, the engine reviews each crew member's recent scratchpad, promotes patterns to their crew knowledge directory AND the canonical DB, prunes stale entries, and updates the crew profile if a new preference or correction was recorded.

6. **Pre-defined landing zones for all knowledge.** No new namespace can be created by an agent. If a discovery doesn't fit a crew member's project, it routes to one of the global categories. Ambiguous entries go to a review queue in WorldTree, not to a random file.

### Non-Goals

| Feature | Reason |
|---------|--------|
| Cross-crew real-time collaboration | Out of scope — each crew member works independently, results aggregate via hierarchy |
| Automatic crew member promotion/demotion | Roles are set by Evan, not by performance metrics |
| New crew member creation by agents | Crew roster is Evan's decision, locked in harness config |
| Rewriting existing crew CLAUDE.md profiles | Profiles stay — this epic wires them to enforcement, not rewrite them |
| Merging cortana-core into WorldTree | Harness daemon stays in cortana-core; DB is shared |

### Knowledge Namespaces (Pre-Seeded, Immutable)

These are the ONLY valid namespaces. Agents route to one. No exceptions.

| Namespace | Scope |
|-----------|-------|
| `world-tree` | WorldTree app — features, architecture, UI, sessions, bridge |
| `bim-manager` | BIM Manager — Plant 3D admin, BOM, columns, user management |
| `archon-cad` | Archon-CAD — Rust CAD engine, egui, commands, file I/O |
| `forge-toolbox` | ForgeToolbox — calculator engine, persistence, iOS |
| `doc-forge` | DocForge — .NET MAUI, document generation |
| `cortana-system` | Cortana infrastructure — harness, daemon, hooks, MCP, brain |
| `project-development` | General engineering patterns — architecture decisions, code quality, testing |
| `job-acquisition` | Business development — client work, revenue, proposals, positioning |
| `forge-and-code` | Company-level — brand, strategy, partnerships, public presence |
| `game-dev` | All game development — design, art, audio, levels, narrative, balance |
| `review-queue` | Unroutable entries awaiting Evan's classification |

### Crew Hierarchy (Hardwired — See CONSTITUTION.md §III–IV for full roster)

**Tier 0 — CEO**
| Who | Role | Capabilities |
|-----|------|-------------|
| Evan Primeau | CEO | Final authority. Approves all epics. The only human in the loop. |

**Tier 1 — CTO**
| Crew | Role | Capabilities |
|------|------|-------------|
| Cortana | CTO / Always-On Brain | Full access to all namespaces and crew. Orchestrates both departments. Default identity for bare terminal sessions. sonnet (opus on escalation only). |

**Tier 2 — Department Heads**
| Crew | Dept | Role | Capabilities |
|------|------|------|-------------|
| Picard | Both | Mission Lead / Epic Architect | Plans epics, assigns crew, defines done. Spawns Leads. sonnet. |

**Tier 3 — Leads (Dual-Role: Coding + Game Dev)**

Crew members hold roles in BOTH departments. Their game dev knowledge lives in their own crew knowledge dirs. The same agent is assigned to either department based on the task.

| Crew | Coding Role | Game Dev Role | Write Namespaces |
|------|-------------|--------------|-----------------|
| Spock | Strategist | Game Director | strategy to any (scoped), `game-dev` |
| Geordi | Architect | Game Architect | assigned project + `project-development` + `game-dev` |
| Data | UI/UX Designer | Art Director | assigned project + `project-development` + `game-dev` |
| Worf | QA Lead | Game QA | assigned project + `game-dev` |
| Torres | Performance Lead | Game Performance | assigned project |
| Dax | Integration Lead | — | assigned project |
| Scotty | Build / DevOps | Game Build | assigned project + `cortana-system` |
| Uhura | Copy / Docs | Narrative Designer | assigned project + `game-dev` |
| Troi | UX Research | Player Experience | `project-development` + `game-dev` |
| Seven | Competitive Intel | — | `job-acquisition` + `project-development` |
| Bashir | Debugging | — | assigned project |
| Garak | Adversarial QA | — | read-only + reports |
| Q | Research | — | `review-queue` only |
| Kim | Documentation | — | assigned project |
| Quark | Marketing | Game Marketing | `job-acquisition` + `forge-and-code` + `game-dev` |
| Composer | — | Music / Audio Lead | `game-dev` |

**Tier 4 — Workers**
| Crew | Coding Specialty | Game Dev Specialty |
|------|-----------------|-------------------|
| O'Brien | CI/CD, App Store | — |
| Paris | Feature implementation | Level Design |
| Nog | SwiftData, CloudKit | Game data, save systems |
| Sato | Localization, accessibility | Platform compliance |
| Odo | Security | — |
| Zimmerman | Diagnostics, crash analysis | — |
| Scotty (worker mode) | — | Game implementation |

Workers: haiku. Read task context + assigned namespace only. Cannot spawn sessions.

### Success Metrics

| Metric | Before | Target |
|--------|--------|--------|
| Knowledge landing accuracy | Unknown — no tracking | 95% of entries in correct namespace after dream cycle |
| Namespace write violations | Undetectable | Zero — enforced at harness layer, logged when blocked |
| Session role consistency | Not enforced | 100% of harness-spawned sessions have injected role prompt |
| Scratchpad-to-knowledge promotion time | Manual, never | Automated per dream cycle (nightly + on session end) |
| Agent knowledge fragmentation | 5+ separate memory locations per crew member | 1 canonical location per crew member + DB |
| New ad-hoc knowledge files created | Uncontrolled | Zero — all writes go through bridge or die |

---

## FRD — Functional Requirements Document

### Architecture Before

```
Agent Session
  ├── Reads: project CLAUDE.md (whatever dir it's in)
  ├── Reads: ~/.cortana/brain/ (if hooks inject it)
  ├── Reads: ~/.cortana/starfleet/crew/{name}/ (if role-specific)
  ├── Writes: ANY FILE IT WANTS
  ├── Spawns: ANY SESSION (no hierarchy check)
  └── Saves: wherever the agent decided to save
```

### Architecture After

```
Harness (enforces everything)
  ├── Assigns: role, namespace, project at spawn time
  ├── Injects: locked system prompt = crew profile + namespace + access rules
  ├── Agent Session (role-locked)
  │   ├── Reads: DB namespace (assigned only)
  │   ├── Reads: crew knowledge (own crew member only)
  │   ├── Writes: bridge_commands → harness validates → DB namespace write
  │   ├── Writes: scratchpad (own namespace, auto-tagged)
  │   ├── Spawns: only roles one tier below (enforced by harness)
  │   └── Cannot: write files directly, access wrong namespace, create namespaces
  └── Dream Engine (nightly + on session end)
      ├── Reads: scratchpad entries for each crew member
      ├── Promotes: patterns, corrections, decisions → crew knowledge + DB
      ├── Prunes: stale entries older than threshold
      └── Updates: crew CLAUDE.md memory section if new preferences logged
```

### Data Model Changes

#### v42: Canonical Knowledge Schema

```sql
-- Single knowledge table, replaces all scattered .md files
CREATE TABLE knowledge (
    id          TEXT PRIMARY KEY,
    namespace   TEXT NOT NULL,                    -- one of the 10 pre-seeded namespaces
    crew_member TEXT,                             -- who wrote it (nullable = system)
    type        TEXT NOT NULL,                    -- CORRECTION|DECISION|PATTERN|ANTI_PATTERN|MISTAKE|PREFERENCE|OBSERVATION
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    why         TEXT,                             -- the reason / incident
    how_to_apply TEXT,                            -- when this rule fires
    confidence  TEXT DEFAULT 'M',                -- H|M|L
    source_session TEXT,                          -- session ID that produced this
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    reviewed_at TEXT,                             -- null = pending review
    promoted_from_scratchpad INTEGER DEFAULT 0
);
CREATE INDEX idx_knowledge_namespace ON knowledge(namespace);
CREATE INDEX idx_knowledge_type ON knowledge(type);
CREATE INDEX idx_knowledge_crew ON knowledge(crew_member);

-- Pre-seed all valid namespaces (insert-only, no agent can add rows)
CREATE TABLE namespaces (
    id          TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    description TEXT
);

-- Crew registry (Evan-managed, harness reads at spawn time)
CREATE TABLE crew_registry (
    name            TEXT PRIMARY KEY,             -- 'picard', 'spock', 'geordi', etc.
    tier            INTEGER NOT NULL,             -- 1=command, 2=strategic, 3=lead, 4=worker
    role_title      TEXT NOT NULL,
    namespaces_read TEXT NOT NULL,                -- JSON array of namespace IDs
    namespaces_write TEXT NOT NULL,               -- JSON array of namespace IDs
    can_spawn_tiers TEXT NOT NULL,                -- JSON array e.g. [3,4]
    profile_path    TEXT NOT NULL,                -- path to CLAUDE.md
    active          INTEGER DEFAULT 1
);
```

#### v43: Scratchpad Namespace Tags (extends v40 scratchpad)

```sql
ALTER TABLE scratchpad ADD COLUMN namespace TEXT;
ALTER TABLE scratchpad ADD COLUMN crew_member TEXT;
ALTER TABLE scratchpad ADD COLUMN promoted INTEGER DEFAULT 0;
ALTER TABLE scratchpad ADD COLUMN promoted_at TEXT;
CREATE INDEX idx_scratchpad_namespace ON scratchpad(namespace, promoted);
CREATE INDEX idx_scratchpad_crew ON scratchpad(crew_member, promoted);
```

#### v44: Knowledge Write Audit Log

```sql
CREATE TABLE knowledge_write_log (
    id           TEXT PRIMARY KEY,
    session_id   TEXT,
    crew_member  TEXT,
    attempted_namespace TEXT,
    assigned_namespace  TEXT,
    blocked      INTEGER DEFAULT 0,       -- 1 = harness rejected it
    reason       TEXT,
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
```

### Feature Specs

#### F0: Terminal Invariance — Bare `claude` = Cortana

A bare `claude` terminal session must always be Cortana (CTO). This is enforced via the global `~/.claude/CLAUDE.md`, which already establishes her identity. This epic strengthens it with:

1. **On session start:** the global CLAUDE.md hooks fire `compass_status` and load the DIRECTOR-BRIEF. This already happens. Add: load the crew_registry summary and inject scratchpad for any active Cortana-level tasks.
2. **Crew work awareness:** If Evan asks Cortana to assign a task to a crew member, she routes it through the harness bridge, not by spawning directly. She never breaks role.
3. **Self-identification:** If a session lacks a crew role in its injected prompt, it IS Cortana. No other identity is valid for an unroled session.

The only sessions that are NOT Cortana are explicitly harness-spawned sessions with an injected crew role. Everything else is the command bridge.

#### F1: Role Injection at Session Spawn

The harness `SessionPool` spawns Claude with a composed system prompt:

```
COMPONENT ORDER:
1. Crew identity block (from crew_registry + crew CLAUDE.md)
2. Role boundaries block (namespaces, tier, what you cannot do)
3. Bridge write protocol (how to save knowledge — only via bridge, not files)
4. Active task context (project, ticket, current goal)
5. Scratchpad context (last N entries for this crew member)
```

The crew member's `CLAUDE.md` is read-only input — it shapes the identity block but the **role boundaries block always wins** if there is a conflict. A worker cannot promote itself by asking nicely.

**API:**
```typescript
interface SpawnOptions {
  crewMember: string;          // must exist in crew_registry
  project: string;             // determines primary namespace
  taskId?: string;             // if assigned to a ticket
  tier?: never;                // derived from crew_registry, not caller-provided
}
```

#### F2: Bridge-Gated Knowledge Writes

All knowledge writes from agent sessions go through the bridge:

```
POST /bridge/command
{
  "type": "knowledge_write",
  "crew_member": "geordi",
  "namespace": "world-tree",        // harness validates against crew_registry
  "knowledge_type": "PATTERN",
  "title": "...",
  "body": "...",
  "why": "...",
  "how_to_apply": "..."
}
```

Harness validation:
1. Is `crew_member` a real crew member? No → reject.
2. Is `namespace` in their `namespaces_write`? No → log to `knowledge_write_log` with `blocked=1`, return error.
3. Is `knowledge_type` valid? No → reject.
4. All fields present? No → reject.
5. Pass → insert into `knowledge` table, return `{"ok": true, "id": "..."}`.

No agent writes directly to any file. There is no other path.

#### F3: Scratchpad as Working Memory (Namespaced)

During a session, agents write observations, half-formed patterns, and in-progress thoughts to the scratchpad:

```
POST /bridge/command
{
  "type": "scratchpad_write",
  "crew_member": "worf",
  "namespace": "archon-cad",
  "content": "Ribbon height measurement: use available_height() not clip_rect().height()"
}
```

Scratchpad entries are ephemeral working memory. They are:
- Auto-tagged with crew_member, namespace, session_id, timestamp
- Visible to the same crew member in future sessions (pre-loaded in context up to last N entries)
- NOT visible to other crew members
- Promoted to `knowledge` by the dream engine when they are high-confidence and unambiguous
- Pruned after 14 days if not promoted

#### F4: Dream Engine — Crew-Aware Consolidation

The dream engine runs:
- Nightly at 02:00 (scheduled via cron / LaunchAgent)
- On session end for any crew member who wrote > 3 scratchpad entries

For each crew member with unreviewed scratchpad entries:

```
DREAM CYCLE:
1. ORIENT — Load crew member's namespace, recent scratchpad entries, existing knowledge
2. GATHER — Group related scratchpad entries by topic
3. PROMOTE — Entries that meet promotion threshold (confidence H, not duplicate):
   a. Insert into `knowledge` table with promoted_from_scratchpad=1
   b. Write to crew member's ~/.cortana/starfleet/crew/{name}/knowledge/ (human-readable)
   c. Mark scratchpad entry as promoted
4. REVIEW-QUEUE — Entries that are ambiguous namespace or low confidence:
   → Insert into `knowledge` with namespace='review-queue'
   → Surface in WorldTree Review Queue panel
5. PRUNE — Delete scratchpad entries older than 14 days that were not promoted
6. PROFILE UPDATE — If a new PREFERENCE or CORRECTION was promoted, append to
   crew member's CLAUDE.md memory section
```

The dream engine uses Ollama local model (qwen2.5:72b) — no API cost.

#### F5: WorldTree — Review Queue Panel

A new panel in WorldTree shows all `knowledge` entries with `namespace='review-queue'`. Evan can:
- Assign to correct namespace (one click → moves the entry)
- Approve for promotion
- Delete

This is the only way new-situation discoveries get properly categorized. Agents cannot self-assign to a new namespace.

#### F6: Crew Registry Management in WorldTree

WorldTree exposes the `crew_registry` table as a read-only panel showing:
- All crew members, their tier, their namespace read/write access
- Active/inactive status
- Last session timestamp

Evan can toggle active/inactive. No agent can modify the registry.

### ContextServer Endpoints

```
GET  /crew                         → all crew members + registry
GET  /crew/{name}/context          → compiled context for spawning (profile + boundaries + scratchpad)
POST /bridge/command               → all agent writes (knowledge, scratchpad, requests)
GET  /bridge/events                → agent-readable events (tasks, commands from WorldTree)
GET  /knowledge?namespace=X&type=Y → read knowledge entries
GET  /knowledge/review-queue       → pending review entries (WorldTree panel)
PATCH /knowledge/{id}/namespace    → assign namespace (Evan only, via WorldTree)
```

### Deletion Manifest

The following are explicitly replaced by this epic. They are not archived — they are superseded:

| Path | What Replaces It |
|------|-----------------|
| `~/.cortana/brain/knowledge/corrections.md` | `knowledge` table, type=CORRECTION |
| `~/.cortana/brain/knowledge/patterns.md` | `knowledge` table, type=PATTERN |
| `~/.cortana/brain/knowledge/anti-patterns.md` | `knowledge` table, type=ANTI_PATTERN |
| `~/.cortana/brain/knowledge/architecture-decisions.md` | `knowledge` table, type=DECISION |
| `~/.cortana/starfleet/crew/*/memory/*.md` | `knowledge` table, crew_member tagged |
| `~/.cortana/harness/pool-state.json` | DB `agent_sessions` table (existing bridge) |

The files are NOT deleted immediately. A migration script reads each file, parses it, and inserts into the `knowledge` table with appropriate namespace and type. Files are removed only after migration is verified.

**Not deleted:**
- `~/.cortana/starfleet/crew/*/CLAUDE.md` — these stay, they are crew identity profiles
- `~/.cortana/starfleet/crew/*/knowledge/craft|systems|vocabulary/` — stay as human-readable reference, but future writes go to DB first, files are generated from DB on dream cycle
- `~/.cortana/brain/DIRECTOR-BRIEF.md` — stays, serves a different purpose (session orientation, not knowledge)

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Harness namespace validation adds latency to all writes | High | Low | Validation is a single DB lookup, <1ms |
| Dream engine promotes wrong namespace | Medium | Medium | Review queue catches it; everything starts reviewed=false |
| Crew profiles conflict with role boundary injection | Medium | High | Role boundary block is ordered AFTER identity in compose — boundaries always override |
| Existing brain knowledge lost during migration | Low | High | Dry-run migration first, verify row count, keep files until verified |
| Agent discovers a path to write files directly | Low | High | Claude Code tool permissions in harness-spawned sessions restrict Bash and Write to approved paths only |
| World Tree crashes mid-dream cycle | Low | Medium | Dream engine runs in harness daemon, not in World Tree process |

### Task Index

**Phase 1 — DB Foundation (unblock everything else)**
- TASK-OS-01: v42 migration — `knowledge`, `namespaces`, `crew_registry` tables
- TASK-OS-02: v43 migration — scratchpad namespace tags
- TASK-OS-03: v44 migration — knowledge_write_log
- TASK-OS-04: Seed `namespaces` table with 10 pre-defined entries
- TASK-OS-05: Seed `crew_registry` with all 24 crew members, tiers, and namespace access lists

**Phase 2 — Harness Enforcement**
- TASK-OS-06: `GET /crew/{name}/context` endpoint — compose role prompt for spawn
- TASK-OS-07: Bridge validation — namespace write enforcement with audit log
- TASK-OS-08: SessionPool spawn — inject crew role prompt at session creation
- TASK-OS-09: Scratchpad write via bridge — namespace + crew tags

**Phase 3 — Dream Engine (builds on EPIC-CORTANA-HARNESS dream engine)**
- TASK-OS-10: Dream engine crew awareness — per-crew scratchpad pass
- TASK-OS-11: Promote logic — scratchpad → knowledge table + crew knowledge dir
- TASK-OS-12: Review queue routing for ambiguous entries
- TASK-OS-13: Profile update step — append CORRECTION/PREFERENCE to crew CLAUDE.md memory section
- TASK-OS-14: Prune step — 14-day scratchpad expiry

**Phase 4 — Knowledge Migration**
- TASK-OS-15: Migration script — brain/knowledge/*.md → knowledge table (corrections, patterns, anti-patterns, decisions)
- TASK-OS-16: Migration script — each crew member's knowledge/ dirs → knowledge table with crew_member + namespace tags
- TASK-OS-17: Migration script — game dev vaults (GAME_DESIGN_VAULT, DND_ART_VAULT, ENVIRONMENT_ART_VAULT, UNREAL_TRANSITION_VAULT, MUSIC_VAULT) → knowledge table, namespace=`game-dev`
- TASK-OS-18: Migration script — crew MEMORY.md files → scratchpad table (recent) + knowledge table (promoted)
- TASK-OS-19: Verification — row counts, spot checks, no data loss, human-readable mirror generation
- TASK-OS-20: Remove migrated .md files (after verification) — the files that are superseded only, never the CLAUDE.md profiles

**Phase 5 — WorldTree UI**
- TASK-OS-21: Review Queue panel — list, assign namespace, approve/delete
- TASK-OS-22: Crew Registry panel — read-only, both departments, tiers, namespace access, last session time
- TASK-OS-23: Knowledge browser — search by namespace, type, crew, date (coding + game dev)

**Phase 6 — Hardening**
- TASK-OS-24: Claude Code permission lockdown in harness-spawned sessions (restrict Write/Bash to approved paths only)
- TASK-OS-25: Namespace write violation alerting in WorldTree
- TASK-OS-26: Dream engine scheduler — nightly LaunchAgent + session-end trigger (both teams)
- TASK-OS-27: Cortana terminal invariance — strengthen global CLAUDE.md hooks to load crew_registry + active scratchpad on bare session start
- TASK-OS-28: End-to-end test — spawn Geordi (coding), write knowledge, verify enforcement, run dream cycle, verify promotion
- TASK-OS-29: End-to-end test — spawn Data (game dev mode), write to `game-dev` namespace, verify routing

---

## Build Order

Phase 1 → Phase 2 → Phase 3 (parallel with Phase 4) → Phase 5 → Phase 6

Phase 1 is the unlock for everything. No phase can begin without its predecessor's DB tables existing.

---

## The Single Document Rule

This epic implements `~/.cortana/CONSTITUTION.md`. That document is the last word on team structure, hierarchy, and knowledge routing. If this epic or any other document conflicts with the CONSTITUTION, the CONSTITUTION wins. When the CONSTITUTION is amended, this epic is updated to match — not the other way around. All prior designs, competing hierarchies, and ad-hoc agent setups are superseded. They are not archived. They are deleted when this ships.

*When this ships, an agent that tries to write a correction to a markdown file simply cannot — the only path is the bridge.*
