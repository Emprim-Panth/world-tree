# EPIC-WT-BRAIN-GOAL-ENGINE: Brain Restructure + Goal-Driven Workflow

**Status:** Planning
**Priority:** High
**Owner:** Evan
**Created:** 2026-04-04
**Tasks:** TASK-001 through TASK-018

---

## PRD — Product Requirements Document

### Problem Statement

The Brain today is a flat knowledge dump. It has `identity/`, `knowledge/`, and `projects/` folders with no sense of team, hierarchy, or organizational structure. When a new session opens, there is no single file it can read to know which agents are available for this project, what the current goal is, or how decisions should be made. The agent team (CIC → Galactica → Pegasus) exists in the `agents/` directory but is completely disconnected from the Brain — there is no file that says "BIM Manager is a Galactica project, Apollo leads it, Chief Tyrol builds it, the goal is X."

Work is also driven by feature lists and ticket queues. There is no concept of a *goal* — a destination that the entire ticket queue is aimed at. This means work can be done that doesn't close the gap toward anything meaningful, and there is no automated way for Cortana or agent leads to ask "what's still between us and done?"

The World Tree Brain panel currently shows a flat list of markdown files and calls it a Brain. It is not a system — it is a file browser wearing a label.

---

### Goals

1. Any new agent session can fully orient itself to a project in one file read — who owns it, what the goal is, which fleet is assigned, what the current state is.
2. The Brain's folder structure mirrors the organizational structure: CIC sits at the top, Galactica and Pegasus are separate fleets, Projects are self-contained, shared Knowledge is shared.
3. Every project can have a Goal — a destination with success criteria and a gap analysis. Tickets trace back to gaps. Gaps trace back to goals.
4. When Evan sets a goal, Cortana and the assigned lead can run a gap analysis: "here is what exists, here is what the goal requires, here are the gaps, here is the ticket order."
5. The World Tree Brain panel becomes a proper file explorer — navigable by org structure, with a dedicated Goal view per project.

---

### Non-Goals

| Feature | Reason Not In Scope | Alternative |
|---------|---------------------|-------------|
| Migrate all existing brain content automatically | Too much domain knowledge to migrate safely without review | Migrate project-by-project as each is activated |
| Replace Compass | Compass handles session state and tickets; this handles organizational knowledge | They integrate — goals link to Compass tickets |
| AI-generated gap analysis (automated) | Phase 1 is human-defined goals + structured gap tables | Phase 2 adds Cortana-generated gap analysis from goal + codebase |
| Ryan's team (F.R.I.D.A.Y.) integration | Different system, different structure | Cross-fleet collaboration is a separate epic |
| Replace the Tickets panel | This epic adds Goals above tickets, not a ticket replacement | Tickets remain as execution layer |

---

### Success Metrics

| Metric | Before | Target |
|--------|--------|--------|
| Time for new session to orient to a project | 3-5 min (read DIRECTOR-BRIEF + find project file) | < 30 sec (read one `_context.md`) |
| Projects with a defined, trackable goal | 0 | All active projects (Archon-CAD, BIM Manager, World Tree) |
| Tickets traceable to a goal | 0% | 100% of new tickets |
| Brain panel usability | Flat list of files, no structure | Tree explorer with org hierarchy, goal view per project |
| Agent context injection on session start | Manual / inconsistent | Automatic from project `_context.md` |

---

### User Stories

1. As **Evan**, I open BIM Manager in World Tree and immediately see the current goal, what's been closed, and what gaps remain — without reading a brief.
2. As **a new Claude session**, I read `BIM-Manager/_context.md` and know: what this project is, which agents to spawn, who the lead is, what the current goal is — all from one file.
3. As **Cortana**, when Evan sets a goal, I can run a gap analysis against the current codebase and generate the gaps table — surfacing what must be built before the goal is met.
4. As **Apollo (Mission Lead)**, I open a project's goal file and see exactly which tickets are closing which gaps — I can route work without asking Evan for context.
5. As **Evan**, I want to tell the system "the goal for BIM Manager is that a Plant 3D admin can do their entire job without touching the database" and have the system respond with a structured breakdown of what that requires, what exists, and what's missing.

---

## FRD — Functional Requirements Document

### Architecture: Before → After

**Before:**
```
~/.cortana/brain/
├── identity/
│   ├── who-i-am.md
│   ├── operating-principles.md
│   ├── behavioral-profile.md
│   ├── relationship-context.md
│   └── slop-profile.md
├── knowledge/
│   ├── corrections.md
│   ├── patterns.md
│   ├── anti-patterns.md
│   ├── architecture-decisions.md
│   └── candidates.md
├── projects/
│   ├── BIM-Manager.md          ← flat file, 106 lines
│   ├── Archon-CAD.md
│   ├── WorldTree.md
│   └── [others]
├── content/
├── sessions/
└── DIRECTOR-BRIEF.md

~/.cortana/agents/              ← completely separate from brain
├── leads/
├── workers/
├── learnings/
└── orchestrator/
```

**After:**
```
~/.cortana/brain/
│
├── CIC/                        ← Command Information Center
│   ├── _manifest.md            ← "What CIC is, who sits here, chain of command"
│   ├── cortana.md              ← Cortana's full profile (from identity/)
│   ├── operating-principles.md ← How we work (from identity/)
│   ├── behavioral-profile.md   ← Decision patterns + biases (from identity/)
│   ├── relationship-context.md ← Evan ↔ Cortana working patterns
│   └── slop-profile.md         ← Weekly slop counteraction profile
│
├── Galactica/                  ← Software fleet (BIM Manager, Archon-CAD, etc.)
│   ├── _manifest.md            ← Fleet roster, domain, chain of command
│   ├── Apollo/
│   │   └── profile.md          ← Mission Lead — role, spawn template, decision authority
│   ├── ChiefTyrol/
│   │   └── profile.md          ← Engineering Lead
│   ├── Starbuck/
│   │   └── profile.md          ← Architecture Lead
│   ├── Tigh/
│   │   └── profile.md          ← QA Lead
│   ├── Gaeta/
│   │   └── profile.md          ← Operations Lead
│   └── learnings.md            ← Fleet-wide patterns, corrections, anti-patterns
│
├── Pegasus/                    ← Game dev fleet (ForgeMaster, etc.)
│   ├── _manifest.md
│   ├── [leads]/                ← Same structure as Galactica
│   └── learnings.md
│
├── Projects/                   ← One folder per project, fully self-contained
│   ├── BIM-Manager/
│   │   ├── _context.md         ← THE context injection file (read this first)
│   │   ├── _team.md            ← Which fleet, which lead, which workers
│   │   ├── goals/
│   │   │   └── GOAL-001-admin-platform.md
│   │   └── knowledge/          ← Project-specific corrections/patterns
│   ├── Archon-CAD/
│   │   ├── _context.md
│   │   ├── _team.md
│   │   ├── goals/
│   │   │   └── GOAL-001-v1-ship.md
│   │   └── knowledge/
│   └── WorldTree/
│       ├── _context.md
│       ├── _team.md
│       ├── goals/
│       │   └── GOAL-001-brain-goal-engine.md
│       └── knowledge/
│
├── Knowledge/                  ← Cross-fleet, shared
│   ├── corrections.md          ← HIGHEST VALUE — Evan corrections
│   ├── patterns.md
│   ├── anti-patterns.md
│   ├── architecture-decisions.md
│   └── candidates.md
│
└── DIRECTOR-BRIEF.md           ← Stays at root — always-first session read
```

**World Tree — Brain Panel: Before → After:**

```
BEFORE:
┌─────────────────────────────────────────────────────────┐
│ [Central Brain] [Project Brain]                         │
│ ┌─────────────────┐ ┌─────────────────────────────────┐ │
│ │ > Director Brief│ │  # Director Brief               │ │
│ │   Corrections   │ │  > Read this FIRST...           │ │
│ │   Patterns      │ │                                 │ │
│ │   Anti-Patterns │ │  [flat markdown content]        │ │
│ │   Architecture  │ │                                 │ │
│ │   Project Notes │ │                                 │ │
│ └─────────────────┘ └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
  Problem: no hierarchy, no team structure, no goal view

AFTER:
┌─────────────────────────────────────────────────────────┐
│ Brain                                    [+ New Goal]   │
│ ┌──────────────────────┐ ┌──────────────────────────────┐│
│ │ 🎯 CIC               │ │ BIM Manager                  ││
│ │   cortana.md         │ │                              ││
│ │   operating-princip… │ │ GOAL-001: Admin Platform     ││
│ │   behavioral-profil… │ │ Status: Active               ││
│ │                      │ │                              ││
│ │ 🚀 Galactica         │ │ ✅ User CRUD                 ││
│ │  ├─ Apollo/          │ │ ✅ Basic reporting            ││
│ │  ├─ ChiefTyrol/      │ │ 🔴 Permission matrix UI      ││
│ │  ├─ Starbuck/        │ │ 🔴 Report timeout fix        ││
│ │  ├─ Tigh/            │ │ 🟡 Export to PDF             ││
│ │  └─ learnings.md     │ │                              ││
│ │                      │ │ Tickets: TASK-089, TASK-090  ││
│ │ 🛸 Pegasus           │ │ Lead: Apollo                 ││
│ │  └─ ...              │ │ Fleet: Galactica             ││
│ │                      │ └──────────────────────────────┘│
│ │ 📁 Projects          │                                 │
│ │  ├─ BIM-Manager/ [●] │                                 │
│ │  ├─ Archon-CAD/  [●] │                                 │
│ │  └─ WorldTree/   [●] │                                 │
│ │                      │                                 │
│ │ 📚 Knowledge         │                                 │
│ │   corrections.md     │                                 │
│ │   patterns.md        │                                 │
│ └──────────────────────┘                                 │
└─────────────────────────────────────────────────────────┘
```

---

### Deletion Manifest

| File / Path | Action | Reason |
|-------------|--------|--------|
| `brain/identity/` | Migrate → `brain/CIC/` | Identity files belong to CIC, not generic identity |
| `brain/knowledge/` | Migrate → `brain/Knowledge/` | Rename for consistency + capitalize |
| `brain/projects/*.md` | Migrate → `brain/Projects/{name}/_context.md` | Flat files become structured project folders |
| `brain/content/` | Migrate → `brain/Knowledge/` or archive | Content notes don't belong in Brain root |
| `brain/sessions/` | Archive | Sessions are ephemeral, not brain state |
| `agents/leads/*.md` | Migrate → `brain/Galactica/{name}/profile.md` | Agent profiles belong in the Brain |
| `agents/workers/*.md` | Migrate → `brain/Galactica/workers/` | Same |
| `agents/learnings/galactica.md` | Migrate → `brain/Galactica/learnings.md` | Belongs in Brain |
| `agents/learnings/pegasus.md` | Migrate → `brain/Pegasus/learnings.md` | Belongs in Brain |
| `agents/learnings/cic.md` | Migrate → `brain/CIC/_manifest.md` | Belongs in Brain |
| `agents/orchestrator/` | Migrate → `brain/CIC/` | Orchestrator IS CIC |

> **Migration, not deletion.** Every file moves with its content intact. Nothing is lost.

---

### Feature Specifications

#### Feature 1: `_context.md` — Project Context File

**Purpose:** The single file any new agent session reads to orient itself to a project. Contains everything needed to start work without additional briefing.

**Schema:**
```markdown
# {Project Name} — Context

**Fleet:** Galactica | Pegasus
**Mission Lead:** Apollo
**Engineering Lead:** Chief Tyrol
**Active Goal:** GOAL-001 — {goal title}
**Compass Status:** [read from compass.db at session start]

## What This Project Is
[2-3 sentences. Purpose, user, problem solved.]

## Current State
[1 paragraph. Where we are right now. What's done, what's not.]

## Which Agents To Use
- Planning / PRD → Starbuck
- Implementation → Chief Tyrol (spawns workers)
- QA gate → Tigh (must approve before ship)
- Deploy → Gaeta

## Do Not
[Project-specific guardrails. E.g. "Do not modify the DXF parser without reading architecture-decisions.md first."]

## Key Files
[3-5 most important paths. Not exhaustive — just the ones a new session must know.]
```

**Constraints:**
- Max 1 page. If it's longer, it's too much.
- Must be updated whenever the Active Goal changes.
- World Tree auto-loads this when a project is selected in Brain view.

---

#### Feature 2: Goal Object

**Purpose:** A Goal is a destination. It lives above the ticket layer and drives gap analysis. A project can have multiple goals but only one `Active` at a time.

**Schema (`goals/GOAL-{N}-{slug}.md`):**
```markdown
# GOAL-{N}: {Title}

**Status:** Active | Achieved | Superseded
**Project:** {project name}
**Fleet:** Galactica | Pegasus
**Lead:** {callsign}
**Created:** {date}
**Target:** {date or milestone}

## The Goal
[One sentence. What does "done" look like from the user's perspective?]

## Success Criteria
[What must be true for this goal to be marked Achieved?]
- [ ] {criterion 1}
- [ ] {criterion 2}
- [ ] {criterion 3}

## Gap Analysis

| Gap | Status | Tickets | Notes |
|-----|--------|---------|-------|
| {what's missing} | 🔴 Open / 🟡 In Progress / ✅ Closed | TASK-N | |

## What This Is NOT
[Explicit scope boundary. Prevents drift.]

## Session Briefing
[What should Cortana say when a new session touches this project?
 Example: "Goal is X. Current gap is Y. Today's work should close Z."]
```

**Constraints:**
- Status is always one of: Active, Achieved, Superseded.
- Only one goal can be Active per project at a time.
- Every new ticket created under a project must map to a Gap in the active goal.
- When all gaps are ✅ Closed, Cortana prompts Evan to mark the goal Achieved.

---

#### Feature 3: Gap Analysis Workflow

**Purpose:** When Evan sets a new Goal, Cortana (with the assigned lead) runs a structured gap analysis — comparing the goal's success criteria against the current project state.

**Trigger:** Evan writes or updates a Goal's success criteria.

**Process:**
```
1. Cortana reads _context.md + the goal file
2. Starbuck (Architecture Lead) reads the codebase
3. For each success criterion:
   a. Does current code satisfy it? → ✅ Closed (no ticket needed)
   b. Does partial work exist? → 🟡 In Progress (surface existing tickets or create)
   c. Does nothing exist? → 🔴 Open (create ticket, assign to appropriate lead)
4. Gap analysis table is populated
5. Cortana presents the gaps to Evan for review before any tickets are created
6. Evan approves → tickets created, linked to goal gaps
```

**Output format:**
```
Gap Analysis: BIM Manager — GOAL-001

✅ Already done (3):
  - User CRUD (TASK-076 merged)
  - Basic permission assignment (TASK-080 merged)
  - Audit log (TASK-082 merged)

🔴 Missing — tickets to create (2):
  - Permission matrix UI (full role×permission grid) → Tigh review first
  - Report generation < 30s (currently 90s+ on large projects)

🟡 Partial — existing work to extend (1):
  - PDF export (TASK-085 in progress — needs completion)

Proposed ticket order: TASK-089 (perf), TASK-090 (matrix), TASK-085 complete
Assign to: Chief Tyrol (TASK-089, TASK-090), current assignee (TASK-085)
Ready to create tickets? (y/n)
```

---

#### Feature 4: World Tree Brain Panel Redesign

**Purpose:** Replace the flat file list with a two-pane file explorer organized by org structure.

**Left pane — Tree:**
- Root nodes: CIC, Galactica, Pegasus, Projects, Knowledge
- CIC: expands to show cortana.md, operating-principles.md, etc.
- Galactica: expands to agent folders (Apollo/, ChiefTyrol/, etc.) + learnings.md
- Pegasus: same as Galactica
- Projects: expands to project folders; each project shows active goal badge
- Knowledge: expands to corrections.md, patterns.md, etc.
- File icons: 🎯 for CIC, 🚀 for Galactica, 🛸 for Pegasus, 📁 for Projects, 📚 for Knowledge
- Active goal indicator (●) on projects with an Active goal

**Right pane — Content:**
- Default: markdown renderer (existing CentralBrainView behavior)
- When a project folder is selected: Goal Summary card at top, then _context.md content below
- When a goal file is selected: Dedicated Goal View (see above)
- When a `_context.md` is selected: Rendered with "Open in Forge" button

**Toolbar:**
- `[+ New Goal]` button — opens goal creation sheet for selected project
- `[Run Gap Analysis]` button — visible only when a goal is selected and status is Active
- Search field — filters tree to matching files

**Swift components:**
- `BrainTreeNode.swift` — recursive tree model (folder / file / project / goal)
- `BrainTreeView.swift` — left pane, replaces flat outline
- `GoalCardView.swift` — goal summary card (status, gaps progress bar, linked tickets)
- `GoalDetailView.swift` — full goal view with gap analysis table
- `BrainContentView.swift` — right pane router (markdown | goal card | context)
- Update `CentralBrainStore.swift` — load new folder structure instead of flat files
- Update `CentralBrainView.swift` — wire in new tree + content views

---

### API Contracts

**New ContextServer endpoints:**

```
GET /brain/project/:name/context
  Response: { context: string, goal: GoalSummary | null, team: TeamSummary }
  Purpose: Context injection for agent sessions

GET /brain/project/:name/goals
  Response: { goals: Goal[], active: Goal | null }

POST /brain/project/:name/goals
  Request: { title: string, criteria: string[], target: string }
  Response: { id: string, path: string }
  Purpose: Create a new goal file

GET /brain/project/:name/goals/:id/gaps
  Response: { gaps: Gap[], summary: GapSummary }
  Purpose: Return gap analysis for a goal

POST /brain/project/:name/goals/:id/gaps
  Request: { gap: string, status: "open"|"in_progress"|"closed", tickets: string[] }
  Response: { updated: boolean }
  Purpose: Update a gap entry
```

**Types:**
```typescript
interface GoalSummary {
  id: string
  title: string
  status: "Active" | "Achieved" | "Superseded"
  openGaps: number
  totalGaps: number
}

interface Gap {
  description: string
  status: "open" | "in_progress" | "closed"
  tickets: string[]
  notes?: string
}
```

---

### Data Model

**Add (compass.db):**

| Table | Schema | Purpose |
|-------|--------|---------|
| `project_goals` | `id TEXT PK, project TEXT, title TEXT, status TEXT, file_path TEXT, created_at TEXT` | Track goals across projects |
| `goal_gaps` | `id TEXT PK, goal_id TEXT FK, description TEXT, status TEXT, tickets TEXT, notes TEXT` | Gap analysis rows |
| `project_context` | `project TEXT PK, fleet TEXT, lead TEXT, active_goal_id TEXT, updated_at TEXT` | Fast lookup for context injection |

**Migration sequence:**
1. Add `project_goals`, `goal_gaps`, `project_context` tables (migration v36)
2. Migrate existing project notes into `Projects/` folder structure (manual, per project)
3. Populate `project_context` from new `_context.md` files as each project is activated

---

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Migration breaks Brain file watchers in CentralBrainStore | High | Medium | Update BrainIndexer paths before migrating any files. Test watcher on new structure first. |
| Goal schema too rigid — real work doesn't fit neatly into gaps | Medium | High | Schema is markdown-based. Free text is always available. Gaps table is optional, not enforced. |
| `_context.md` gets stale — agents work from wrong goal | Medium | High | World Tree shows last-updated timestamp. Cortana checks context age on session start and warns if > 7 days without update. |
| CentralBrainView rewrite scope grows | High | Medium | Phase the UI work: Phase 1 = folder structure only (existing viewer), Phase 2 = Goal view. Never both at once. |
| Agent context injection not adopted consistently | Medium | Medium | Bake into harness dispatcher — every agent spawn reads `_context.md` automatically, not optionally. |

---

## Task Index

| Task | Title | Priority | Phase |
|------|-------|----------|-------|
| TASK-001 | Design + finalize Brain folder schema (CIC/Galactica/Pegasus/Projects/Knowledge) | Critical | 1 |
| TASK-002 | Migrate brain/identity/ → brain/CIC/ | Critical | 1 |
| TASK-003 | Migrate agents/learnings/cic.md → brain/CIC/_manifest.md | Critical | 1 |
| TASK-004 | Migrate agents/leads/ + agents/learnings/galactica.md → brain/Galactica/ | Critical | 1 |
| TASK-005 | Migrate agents/learnings/pegasus.md + Pegasus leads → brain/Pegasus/ | Critical | 1 |
| TASK-006 | Create brain/Projects/ — BIM-Manager, Archon-CAD, WorldTree folders | Critical | 1 |
| TASK-007 | Write _context.md for each active project (BIM Manager, Archon-CAD, World Tree) | Critical | 1 |
| TASK-008 | Write _team.md for each active project | High | 1 |
| TASK-009 | Migrate brain/knowledge/ → brain/Knowledge/ | High | 1 |
| TASK-010 | Update BrainIndexer paths to new folder structure | Critical | 1 |
| TASK-011 | Update CentralBrainStore.swift to load new structure | Critical | 1 |
| TASK-012 | Build BrainTreeNode.swift + BrainTreeView.swift (left pane file explorer) | High | 2 |
| TASK-013 | Build BrainContentView.swift — right pane router | High | 2 |
| TASK-014 | compass.db migration v36 — project_goals, goal_gaps, project_context tables | High | 2 |
| TASK-015 | Build GoalCardView.swift + GoalDetailView.swift | High | 2 |
| TASK-016 | Add ContextServer endpoints for goals + context injection | High | 2 |
| TASK-017 | Wire harness dispatcher to auto-load _context.md on every agent spawn | Critical | 2 |
| TASK-018 | Write GOAL-001 for BIM Manager + run first gap analysis | Medium | 3 |

**Sequence constraints:**
- Phase 1 (TASK-001–011): File structure migration must be complete before any UI work. TASK-010 and TASK-011 are the last Phase 1 tasks — they re-point the watchers at the new paths.
- Phase 2 (TASK-012–017): UI + goal engine. TASK-014 (DB migration) must precede TASK-015 and TASK-016.
- Phase 3 (TASK-018): First real use of the system. Validates everything.
- TASK-017 is Phase 2 but can run in parallel with UI work — it's a harness change, not Swift.

---

*Epic planned 2026-04-04. 💠*
