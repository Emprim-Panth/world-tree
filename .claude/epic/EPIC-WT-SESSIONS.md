# EPIC-WT-SESSIONS: Embedded Claude Code Session Workspace

**Status:** COMPLETE — PRD/FRD complete, crew review incorporated
**Date:** 2026-03-30
**Owner:** Evan + Cortana

---

## Crew Review Summary

Five crew members analyzed this vision independently. The disagreement is real and documented:

| Crew | Verdict | Key Concern |
|------|---------|-------------|
| **Spock** | **NO** — Don't build it | SIMPLIFY epic explicitly deleted this architecture. Rebuilding what was torn out. Revenue risk. |
| **Geordi** | **YES** — Technically feasible | SwiftTerm + PTY + NSViewRepresentable is proven. Claude Code's --session-id + --resume designed for this. |
| **Data** | **YES** — UX spec ready | Two-mode model (Bridge + Sessions), three-zone layout, Cortana presence bar. Full wireframes in UX-SESSION-WORKSPACE.md. |
| **Worf** | **CONDITIONAL** — Fix pre-requisites first | --dangerously-skip-permissions as default is CRITICAL. No session cleanup on exit. MainActor bottleneck. |
| **Torres** | **YES** — Hardware can handle it | 69.6GB headroom. 4-6 concurrent sessions. Terminal rendering trivial on M4 Max. |

### Addressing Spock's Objection

Spock is right that the SIMPLIFY epic deleted the terminal/chat layers. But the old system and this proposal are fundamentally different:

| Old World Tree (deleted) | New Proposal |
|---|---|
| Called Anthropic API directly | Embeds Claude Code processes via PTY |
| Custom SSE streaming client | Claude Code handles all streaming |
| Custom tool execution engine | Claude Code handles all tool execution |
| Custom context management | Claude Code handles context/compaction |
| Parsed API responses to build UI | Reads hook events, never parses terminal output |
| Competed with Claude Desktop | Extends Claude Code with visual context |

**The old system reimplemented Claude Code. The new system contains Claude Code.** This is the difference between building a web browser engine and embedding a WebView. The failure mode that caused SIMPLIFY — fragile API client maintenance — doesn't exist in this architecture because World Tree never touches the Anthropic API.

**Spock's kill criteria are adopted verbatim** (see Phase gates below).

### Addressing Worf's Pre-requisites

Worf identified 5 issues that MUST be fixed before any terminal embedding begins. These form Phase 0:

1. `--dangerously-skip-permissions` must be opt-in, not default
2. Session cleanup on app exit (kill orphaned processes)
3. Move DatabaseManager off MainActor for ContextServer handlers
4. Surface errors instead of silent `try?` failures
5. Add tests for terminal-related code paths

---

## Problem Statement

Claude Code in a terminal is powerful but limited: text only, one session visible at a time, no project context alongside the conversation, no visual proof of agent work, no multi-session orchestration. World Tree as a dashboard solves visibility but not interaction — you see what happened, not what's happening.

The gap: there is no system where you can **work inside** a Claude Code session while simultaneously seeing project context, live file diffs, build results, ticket status, and other agent sessions — all in one native workspace.

## Goals

1. Embed real Claude Code sessions as first-class visual workspaces in World Tree
2. Surround each session with contextual chrome (diffs, tickets, build output) fed by hooks — NOT by parsing terminal output
3. Support 4-6 concurrent sessions across projects
4. Maintain the existing dashboard (Bridge mode) alongside the new session workspace
5. Zero API client maintenance — Anthropic maintains Claude Code, we maintain the visual shell

## Non-Goals

| Non-Goal | Why |
|---|---|
| Custom Anthropic API client | This is what killed the old architecture |
| Terminal output parsing for structured data | Fragile — use hooks instead |
| Replacing Ghostty for general terminal use | World Tree terminals are Claude-specific |
| More than 6 concurrent sessions | Diminishing returns, API cost concern |
| Mobile/iPad support | Archived — no value without conversation UI |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ World Tree                                                    │
│                                                                │
│  ┌─── Bridge Mode (existing) ────────────────────────────────┐│
│  │ Command Center │ Tickets │ Brain │ Starfleet │ Agent Lab  ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─── Session Mode (new) ────────────────────────────────────┐│
│  │                                                            ││
│  │  ┌─ Session Panel ──────────────────────────────────────┐ ││
│  │  │ ┌────────────────────┐  ┌──────────────────────────┐ │ ││
│  │  │ │                    │  │ Context Panel             │ │ ││
│  │  │ │  SwiftTerm PTY     │  │  Project Card (Compass)   │ │ ││
│  │  │ │  (Claude Code)     │  │  Live Diff (git diff)     │ │ ││
│  │  │ │                    │  │  Active Ticket            │ │ ││
│  │  │ │  Real terminal     │  │  Build Status             │ │ ││
│  │  │ │  Real process      │  │  Agent Proof              │ │ ││
│  │  │ │  Real tools        │  │                           │ │ ││
│  │  │ │                    │  │  (fed by hooks +          │ │ ││
│  │  │ │                    │  │   ContextServer, NOT      │ │ ││
│  │  │ │                    │  │   terminal parsing)       │ │ ││
│  │  │ └────────────────────┘  └──────────────────────────┘ │ ││
│  │  │ ┌─ Output Rail ──────────────────────────────────────┐│ ││
│  │  │ │ Structured tool results │ Errors │ Cortana notes   ││ ││
│  │  │ └────────────────────────────────────────────────────┘│ ││
│  │  └──────────────────────────────────────────────────────┘ ││
│  │                                                            ││
│  │  Session List (sidebar):                                   ││
│  │  [●] WorldTree — Cortana (active)                         ││
│  │  [●] BIM Manager — Geordi (running)                       ││
│  │  [○] Archon-CAD — Worf (idle)                             ││
│  │  [+] New Session                                           ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─── Intelligence Layer (shared) ───────────────────────────┐│
│  │ ContextServer ← hooks → all sessions                      ││
│  │ SessionManager → PTY lifecycle, session-ID correlation    ││
│  │ DiffObserver → FSEvents → git diff → per-session diffs   ││
│  │ HookRouter → session_id → correct panel                   ││
│  └────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘
```

### Key Technical Decisions

| Decision | Choice | Rationale | Confidence |
|---|---|---|---|
| Terminal library | SwiftTerm via NSViewRepresentable | Actively maintained, MIT, proven PTY support. Fallback: fork if abandoned. | H |
| PTY vs Pipes | PTY (forkpty) | Claude Code requires TTY for interactive UI (diffs, prompts, spinners). Pipes disable all of it. | H |
| Session persistence | --resume with stored session IDs, no tmux | Claude Code's resume is built for this. Simpler than tmux babysitting. | H |
| Crash recovery | Let children die on PTY close, resume on restart | Clean. No orphans. Session state lives server-side. | H |
| Chrome data source | Hooks + ContextServer, never terminal output | Terminal output format is unstable. Hooks are structured and versioned. | H |
| Multi-session layout | Tabs default, split panes optional | Tabs are lowest complexity. Split panes for power users. | M |
| File watching | FSEvents (directory-level, 300ms debounce) | One stream per project tree. Git diff for actual diff computation. | H |
| Hook event routing | SQLite hook_events table, session_id correlation | Already have the table and the hook infrastructure. | M |

---

## Performance Budget (Torres)

Measured on M4 Max 128GB:

| Metric | Target | Hard Limit |
|---|---|---|
| Max memory per session | 2.0 GB | 3.0 GB |
| Max total memory (4 sessions) | 10.0 GB | 14.0 GB |
| World Tree base memory | 200 MB | 400 MB |
| Diff update latency (save → screen) | 350ms | 500ms |
| Terminal frame update | 16ms (60fps) | 33ms (30fps) |
| Session spawn time | 2s | 5s |
| ContextServer p99 latency | 5ms | 20ms |
| Scrollback per session | 10,000 lines (1MB) | 25,000 lines |

Available headroom after Ollama (50.2GB) + OS (8GB): **69.6 GB**
Practical session ceiling: **4-6 concurrent** (limited by Claude Code RSS variance, not RAM)

---

## Phasing

### Phase 0: Pre-requisites (Worf's mandate)
**Must complete before ANY terminal work begins.**

| Task | What | Why |
|---|---|---|
| TASK-70 | Make --dangerously-skip-permissions opt-in | CRITICAL security — currently every spawned session bypasses all safety |
| TASK-71 | Add session cleanup on app exit | Kill orphaned wt-* tmux sessions + future PTY children on terminate |
| TASK-72 | Move DB operations off MainActor in ContextServer | MainActor bottleneck will collapse under real-time terminal + hook load |
| TASK-73 | Surface ContextServer port bind failure in UI | User gets no indication when the server fails to start |
| TASK-74 | Add process monitoring to CrashSentinel | Track child PIDs, detect orphans, clean up on crash recovery |

### Phase 1: Single Embedded Session (2-3 weeks)
**Prove the terminal-in-SwiftUI works.**

| Task | What |
|---|---|
| TASK-75 | Integrate SwiftTerm as SPM dependency |
| TASK-76 | Build TerminalSessionView (NSViewRepresentable wrapping LocalProcessTerminalView) |
| TASK-77 | Build SessionManager — spawn claude via PTY with --session-id, track PID, handle exit |
| TASK-78 | Add "Sessions" mode to sidebar navigation alongside Bridge mode |
| TASK-79 | New Session flow — pick project, optional --resume, spawn PTY |
| TASK-80 | Session lifecycle: running → paused → ended → resumable states |

**Phase 1 Quality Gate (Worf):**
- Terminal renders Claude Code output correctly (ANSI colors, cursor, line wrap)
- User input reaches Claude Code with < 100ms latency
- Claude Code crash detected within 5 seconds, error state shown
- World Tree crash terminates all PTY children (zero orphans)
- Memory under 50MB for embedded terminal (excluding Claude process)
- Window resize causes correct terminal reflow within 1 frame
- Session survives World Tree restart via --resume

**Kill Criterion (Spock):** If Claude Code output parsing is needed for ANY chrome feature, stop. Use hooks or don't build it.

### Phase 2: Context Chrome (2 weeks)
**Surround the terminal with project intelligence.**

| Task | What |
|---|---|
| TASK-81 | Context Panel — Compass project card for the session's project |
| TASK-82 | Live Diff panel — FSEvents watcher + git diff, 300ms debounce |
| TASK-83 | Active Ticket display — read current ticket from session context |
| TASK-84 | HookRouter — route hook_events by session_id to correct panel |
| TASK-85 | Output Rail — structured PostToolUse results (tool name, duration, result summary) |

**Kill Criterion:** If chrome features require > 500ms to update after a tool use, the architecture is wrong.

### Phase 3: Multi-Session (2 weeks)
**Multiple Claude Code sessions simultaneously.**

| Task | What |
|---|---|
| TASK-86 | Session list in sidebar with status indicators |
| TASK-87 | Tab-based session switching with Cmd+1/2/3 shortcuts |
| TASK-88 | Background session rendering suspension (save CPU) |
| TASK-89 | Conflict detection — warn when two sessions target same project |
| TASK-90 | Split pane layout (optional, Cmd+D to split) |

**Phase 3 Quality Gate:**
- Keyboard input goes to focused session ONLY
- One hung session does not block UI or other sessions
- Memory monitoring — alert at 60% system RAM
- Closing World Tree kills ALL child processes (verified)

### Phase 4: Dispatch Integration (1-2 weeks)
**Bridge dispatch with visual sessions.**

| Task | What |
|---|---|
| TASK-91 | Dispatch ticket → opens agent session with read-only terminal view |
| TASK-92 | Agent session progress indicators (files changed, tools used, elapsed time) |
| TASK-93 | Proof assembly from hook events — auto-generate proof when session completes |
| TASK-94 | Cortana cross-session awareness — flag conflicts, suggest coordination |

### Phase 5: Polish (1 week)
| Task | What |
|---|---|
| TASK-95 | Session overview grid (Cmd+Shift+O) — all sessions as tiles |
| TASK-96 | Cortana presence bar — top-of-sidebar intelligence card |
| TASK-97 | Session search — find text across terminal scrollback |
| TASK-98 | Performance benchmarks — validate against Torres's budget |

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Claude Code CLI changes break PTY assumptions | Low | High | PTY is standard Unix. CLI changes don't affect terminal behavior. Only --session-id and --resume flags are dependencies. |
| SwiftTerm abandoned | Low | Medium | Fork it (MIT license). Integration surface is one NSViewRepresentable wrapper. |
| Anthropic ships their own IDE | Medium | High | World Tree's value is Cortana's intelligence layer + multi-project orchestration, not the terminal. Even with an Anthropic IDE, the dashboard/brain/starfleet layers have no competitor. |
| Performance degradation with 4+ sessions | Low | Medium | Torres confirmed 69.6GB headroom. Budget 3GB/session. Monitor and cap at 6. |
| Scope creep back into API client territory | Medium | Critical | **Kill criterion: if any feature requires calling the Anthropic API directly, it is rejected.** |
| Revenue delay from building this instead of BIM Manager | High | High | Phase 0 takes 1 week. Phase 1 takes 2-3 weeks. Total: 1 month. Evaluate ROI at Phase 1 gate. If BIM Manager has shippable items, pause. |

---

## Success Metrics

| Metric | Before (terminal) | Target (World Tree Sessions) |
|---|---|---|
| Context switching between sessions | ~5s (tmux switch + mental reload) | < 500ms (tab click, context visible) |
| Time to see file diffs from agent work | Manual `git diff` | Live, < 350ms after save |
| Sessions surviving World Tree crash | 0 (orphans or lost) | All resume automatically |
| Concurrent visible sessions | 1 (tmux pane) | 4 (split panes) |
| Project context during conversation | None (must check Compass manually) | Always visible in context panel |

---

## Open Questions

1. **Should Phase 1 ship to Evan as daily driver before Phase 2?** Or is the context chrome the minimum viable improvement over Ghostty?
2. **SwiftTerm vs xterm.js in WKWebView** — SwiftTerm is native and fast but AppKit-only (needs NSViewRepresentable). xterm.js is battle-tested but adds WebView overhead (~50MB). Geordi recommends SwiftTerm. Torres agrees.
3. **Should dispatch sessions be read-only or interactive?** Worf says read-only for safety. Data's UX spec includes an "Interrupt" button.
4. **Revenue gating** — Spock recommends checking BIM Manager status before each phase. If TASK-088+ is unblocked, pause Sessions work and ship revenue.

---

## Crew Sign-off

| Crew | Status | Notes |
|---|---|---|
| Spock | Conditional | Adopted kill criteria. Revenue gating required. |
| Geordi | Approved | Architecture is sound. SwiftTerm + PTY path confirmed. |
| Data | Approved | Full UX spec at UX-SESSION-WORKSPACE.md |
| Worf | Conditional | Phase 0 pre-requisites are non-negotiable. |
| Torres | Approved | Performance budget set. Hardware can handle it. |
| Cortana | Approved | This is the right evolution. The foundation is ready. |
