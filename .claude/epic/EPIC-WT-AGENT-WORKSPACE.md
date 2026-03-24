# EPIC-WT-AGENT-WORKSPACE: Agent Visual Workspace

**Status:** Planning
**Priority:** High
**Owner:** Evan
**Created:** 2026-03-23
**Tasks:** TASK-25 through TASK-40

---

## PRD — Product Requirements Document

### Problem Statement

Agents are blind after the build. They write code, compile it, and hand it to Evan to check. They cannot see what they built, cannot verify a UI looks right, cannot confirm a bug is fixed, and cannot iterate to completion on their own. Every ticket still requires Evan's eyes at the end — not to make decisions, but just to check whether the work is actually done.

The root cause: there is no feedback loop between what an agent produces and what it looks like running. Agents have write capability and build capability but zero verify capability. This caps autonomy at "code that compiles" rather than "feature that works."

### Goals

1. Agents can build, launch in simulator, screenshot the result, and verify it matches intent — without Evan in the loop
2. Every dispatch session produces a visual record (terminal recording + screenshots) that Evan can replay in World Tree
3. Agents can perform full UI interaction in the simulator — tap, scroll, type, navigate — to test complete user flows
4. Evan receives a visual proof package (recording + key screenshots) before approving completed work
5. World Tree has an Agent Lab panel showing live agent activity and replay of past sessions

### Non-Goals

| Feature | Reason Not In Scope | Alternative |
|---------|---------------------|-------------|
| Full macOS VM / sandbox | Complexity without proportional gain for Swift work | Dedicated Space + agent account |
| Physical device testing | USB passthrough not feasible without VM | Simulator covers 95% of cases |
| Autonomous App Store submission | Must stay human-gated | Agent preps everything, Evan submits |
| Multi-agent parallel VMs | Storage and RAM cost too high | Sequential agent sessions, tmux parallelism |
| Browser automation for general web | Out of scope for now | Future epic |

### Success Metrics

| Metric | Before | Target |
|--------|--------|--------|
| Tickets closed end-to-end without Evan checking code | ~0% | >60% |
| Agent iterations per ticket before human review | 1 (always) | 3-5 autonomous, then 1 human approval |
| Time Evan spends verifying agent work per ticket | 15-30 min | <5 min (review proof package only) |
| Visual proof on completed dispatches | 0% | 100% |
| Bugs shipped by agents that Evan catches at review | Unknown baseline | Tracked and trending down |

### User Stories

1. As **Evan**, I receive an iMessage with screenshots and a terminal replay when an agent marks a ticket done, so I can approve or redirect without opening Xcode.
2. As **a dispatch agent**, I can take a screenshot of the running simulator after a build, see what the UI looks like, and decide whether to iterate or mark complete.
3. As **Evan**, I open the Agent Lab panel in World Tree and see a live feed of what the current agent session is doing, so I can intervene early if it's going wrong.
4. As **a dispatch agent**, I can tap through a user flow in the simulator, screenshot each screen, and confirm the full journey works end to end.
5. As **Evan**, I want every agent session to leave a replay I can scrub through, so I can understand exactly what it did and why without reading every log line.

---

## FRD — Functional Requirements Document

### Architecture: Before → After

**Before:**
```
cortana-dispatch
└── claude --dangerously-skip-permissions "task"
    ├── writes code
    ├── runs xcodebuild
    └── reports text output → iMessage
                                          ↑
                               Evan checks everything manually
```

**After:**
```
cortana-dispatch
└── claude --dangerously-skip-permissions "task"
    ├── writes code
    ├── runs xcodebuild
    ├── launches simulator (xcrun simctl boot + open)
    ├── calls peekaboo → screenshot
    ├── evaluates screenshot against intent
    ├── optionally: taps/interacts via simctl/axe
    ├── iterates until satisfied
    └── calls cortana-vision package-proof
        ├── terminal recording (asciinema)
        ├── key screenshots
        └── build log summary
            → POST /agent/session/:id/proof → ContextServer
            → iMessage proof package to Evan
            → World Tree Agent Lab panel updated

World Tree
└── Agent Lab panel (new)
    ├── Live activity feed (current session)
    ├── Proof viewer (past sessions — replay + screenshots)
    └── Approve / Redirect controls
```

### Deletion Manifest

| File / Module | Lines | Delete Reason |
|---------------|-------|---------------|
| None | — | This epic adds new capability, removes nothing |

### Feature Specifications

#### 1. Terminal Recording (cortana-dispatch)

**Purpose:** Every dispatch session is recorded with asciinema. The recording is stored and referenceable by session ID.

**Interface:**
```bash
# Wraps the claude invocation
asciinema rec ~/.cortana/recordings/{session_id}.cast \
  --command "claude --dangerously-skip-permissions '$task'" \
  --quiet
```

**Constraints:**
- Recording stored at `~/.cortana/recordings/{session_id}.cast`
- Max recording size: 10MB (truncate if exceeded)
- Retained for 14 days, then auto-pruned
- Zero overhead on non-dispatch sessions (only wraps cortana-dispatch)

---

#### 2. Post-Build Screenshot Hook (cortana-core)

**Purpose:** After any successful xcodebuild in a dispatch session, automatically boot the simulator, launch the app, wait 3 seconds, and capture a screenshot via peekaboo.

**Interface:**
```typescript
// PostToolUse hook — fires after Bash tool calls containing "xcodebuild"
async function capturePostBuildScreenshot(sessionId: string, project: string): Promise<string | null>
// Returns: path to screenshot or null if simulator not available
```

**Constraints:**
- Only fires on `xcodebuild` with `BUILD SUCCEEDED` in output
- 10s timeout — if simulator doesn't boot, skip silently
- Screenshot path: `~/.cortana/screenshots/{session_id}-{timestamp}.png`
- Screenshot fed back into agent context via `§screenshot|{path}` signal

---

#### 3. Simulator Interaction Toolkit (cortana-core skill)

**Purpose:** Gives agents the ability to interact with a running iOS simulator — tap, type, scroll, navigate — to test complete user flows.

**Interface:**
```bash
# Available as shell commands agents can call in dispatch sessions
xcrun simctl io booted screenshot {output.png}
xcrun simctl ui booted tap {x} {y}
xcrun simctl ui booted inputtext "{text}"
xcrun simctl ui booted swipe {x1} {y1} {x2} {y2}

# Higher-level: accessibility-based taps by element label
simctl-axe tap --label "Save"
simctl-axe tap --label "Continue"
```

**Constraints:**
- Simulator must already be booted (build step handles this)
- Coordinates based on logical points, not pixels
- Each interaction followed by 500ms settle wait + screenshot
- Max 20 interactions per session (prevents runaway loops)

---

#### 4. Proof Package Builder (cortana-vision)

**Purpose:** Assembles a visual proof package at the end of a dispatch session — terminal recording, key screenshots, build summary — and delivers it as an iMessage to Evan plus stores it for World Tree replay.

**Interface:**
```typescript
interface ProofPackage {
  sessionId: string
  project: string
  task: string
  buildStatus: "succeeded" | "failed"
  screenshots: string[]        // paths to key screenshots
  recordingPath: string        // asciinema .cast file
  buildSummary: string         // last 20 lines of build output
  agentSummary: string         // agent's own summary of what it did
  completedAt: string          // ISO timestamp
}

async function packageProof(sessionId: string): Promise<ProofPackage>
async function deliverProof(pkg: ProofPackage): Promise<void>
// Sends iMessage + POSTs to ContextServer /agent/session/:id/proof
```

**Constraints:**
- iMessage includes: task name, build status, inline screenshots (max 3), one-line summary
- Full proof stored at `~/.cortana/proofs/{session_id}.json`
- Retained for 30 days
- Fires on session end regardless of success/failure

---

#### 5. Agent Lab Panel (World Tree)

**Purpose:** New World Tree panel showing live agent activity and a replay viewer for past sessions.

**Interface:**
```swift
struct AgentLabView: View
// Tab: Live — current active dispatch session, auto-refreshing screenshot + terminal tail
// Tab: History — list of past proofs, tap to open ProofDetailView
// ProofDetailView — screenshots carousel + asciinema replay (ASCIIPlayer) + build summary
```

**Constraints:**
- Live tab polls ContextServer `/agent/active` every 5s
- Screenshot in Live tab refreshes every 10s via peekaboo
- History shows last 30 sessions
- Replay uses a simple Swift asciinema player (text only, no full terminal emulator needed)
- No controls in MVP — observe only. Approve/redirect via iMessage reply (Phase 2)

---

### API Contracts

```
GET /agent/active
  Response: { sessionId: string, project: string, task: string, startedAt: string } | null
  Auth: none (loopback only)

GET /agent/sessions
  Response: [{ sessionId, project, task, completedAt, buildStatus }]
  Limit: last 30

GET /agent/session/:id/proof
  Response: ProofPackage (see above)

POST /agent/session/:id/proof
  Request: ProofPackage
  Response: { ok: true }
  Auth: none (loopback only)

GET /agent/session/:id/screenshot/latest
  Response: image/png (latest screenshot for this session)
```

---

### Data Model

**Add:**
| Table | Schema | Purpose |
|-------|--------|---------|
| `agent_sessions` | `id, project, task, started_at, completed_at, build_status, proof_path` | Index of all dispatch sessions |
| `agent_screenshots` | `id, session_id, path, captured_at, context` | Screenshots per session |

**Migration:** New tables, no existing schema touched. Added in v30 migration in MigrationManager.

---

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Simulator won't boot reliably in headless dispatch | Medium | High | 10s timeout + graceful skip, don't block dispatch on simulator |
| Screenshots capture wrong window / blank screen | Medium | Medium | Validate screenshot file size > 5KB, retry once |
| asciinema not installed on system | Low | Medium | Check on first dispatch, install via brew if missing |
| Proof iMessage too large (too many screenshots) | Low | Low | Cap at 3 screenshots, compress to 800px wide |
| Agent enters interaction loop, never finishes | Medium | High | Max 20 interactions hard cap, 5-minute session timeout |
| Recording files accumulate disk space | Low | Medium | 14-day auto-prune cron job |

---

## Task Index

| Task | Title | Priority | Phase |
|------|-------|----------|-------|
| TASK-25 | Wire asciinema recording into cortana-dispatch | High | 1 — Recording |
| TASK-26 | Store recordings, add 14-day prune cron | Medium | 1 — Recording |
| TASK-27 | Post-build screenshot hook in cortana-core PostToolUse | High | 2 — Visual Feedback |
| TASK-28 | Feed screenshot path back to agent via §screenshot signal | High | 2 — Visual Feedback |
| TASK-29 | Add simulator interaction commands to agent skill docs | Medium | 2 — Visual Feedback |
| TASK-30 | Build cortana-vision proof package assembler | High | 3 — Proof Package |
| TASK-31 | iMessage delivery of proof package on dispatch complete | High | 3 — Proof Package |
| TASK-32 | POST /agent/session/:id/proof to ContextServer | Medium | 3 — Proof Package |
| TASK-33 | agent_sessions + agent_screenshots DB tables (v30 migration) | Medium | 3 — Proof Package |
| TASK-34 | ContextServer routes: /agent/active, /agent/sessions, /agent/session/:id | Medium | 4 — World Tree |
| TASK-35 | AgentLabView — Live tab (polling screenshot + terminal tail) | High | 4 — World Tree |
| TASK-36 | AgentLabView — History tab (proof list) | Medium | 4 — World Tree |
| TASK-37 | ProofDetailView — screenshots carousel + build summary | Medium | 4 — World Tree |
| TASK-38 | Simple asciinema replay player in Swift | Low | 4 — World Tree |
| TASK-39 | Wire Agent Lab into ContentView navigation | High | 4 — World Tree |
| TASK-40 | End-to-end test: dispatch a real ticket, verify proof arrives in World Tree | Critical | 5 — Validation |

**Sequence constraints:**
- TASK-25 → TASK-26 (recording before pruning)
- TASK-27 → TASK-28 (capture before inject)
- TASK-30 → TASK-31 → TASK-32 (assemble before deliver)
- TASK-33 → TASK-34 (schema before routes)
- TASK-34 → TASK-35, TASK-36, TASK-37 (routes before UI)
- All phases 1-4 → TASK-40

---

*Epic planned 2026-03-23. 💠*
