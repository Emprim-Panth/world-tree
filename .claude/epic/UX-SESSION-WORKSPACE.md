# UX Design: Session Workspace — Embedded Terminal Intelligence

**Author:** Data (UI/UX Specialist)
**Date:** 2026-03-29
**Status:** Design Proposal
**Scope:** Transform World Tree from a dashboard app into a multi-session terminal workspace with live context panels

---

## 1. Information Architecture

### The Problem with "Tabs vs. Replace"

World Tree today is a dashboard: Command Center, Tickets, Brain, Agent Lab, Starfleet, Settings — all behind a `NavigationSplitView` with a sidebar list and a detail panel. It shows you things. The new vision is a workspace where you *do* things — embedded Claude Code terminals surrounded by live context.

These are different modes of use, not different features. The dashboard answers "what's happening across all my projects?" The workspace answers "what am I building right now?" Forcing one to replace the other kills whichever mode you're not in.

### The Model: Two Modes, One App

```
World Tree
├── Bridge (Dashboard Mode)       ← Current Command Center, evolved
│   ├── Project Grid
│   ├── Dispatch Activity
│   ├── Intelligence Dashboard
│   ├── Tickets
│   ├── Brain
│   └── Starfleet
│
└── Sessions (Workspace Mode)     ← NEW: Embedded terminal workspace
    ├── Session List / Switcher
    ├── Active Session Workspace
    │   ├── Terminal (center)
    │   ├── Context Panel (right)
    │   └── Output Rail (bottom)
    └── Session Overview (multi-session grid)
```

**Navigation:** The sidebar gains exactly two top-level entries that matter:

```
┌─────────────────────┐
│ ◈ Cortana           │  ← Cortana's presence: alerts, briefing
│                     │
│ BRIDGE              │
│  ◇ Dashboard        │  ← Current Command Center
│  ◇ Tickets          │
│  ◇ Brain            │
│  ◇ Starfleet        │
│                     │
│ SESSIONS            │
│  ● BIM Manager      │  ← Active session (green dot)
│  ○ WorldTree        │  ← Idle session
│  + New Session      │  ← Create
│                     │
│ ─────────           │
│  ◇ Settings         │
└─────────────────────┘
```

**Why this works:**
- Bridge mode is the "lean back" view. You open World Tree, see everything at a glance, decide what to work on.
- Sessions mode is the "lean forward" view. You're in a terminal, building, with context wrapping the work.
- Sessions show in the sidebar as a live list. You see which ones are active without switching modes.
- The sidebar is persistent. You can jump from a session directly to Tickets and back without losing terminal state.

**Keyboard:** `Cmd+1` = Dashboard, `Cmd+2` through `Cmd+5` = sessions by order, `Cmd+N` = new session.

---

## 2. Session Workspace Layout

### Single Active Session

The workspace for one session is a three-zone layout inspired by Xcode and Zed, but terminal-first:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ◈ BIM Manager  ·  main  ·  3 uncommitted  │  ▶ Build   │  ◉ Recording  │  │
├──────────────────────────────────────────────┬──────────────────────────────┤
│                                              │ CONTEXT                      │
│                                              │                              │
│              TERMINAL                        │ ┌──────────────────────────┐ │
│                                              │ │ 📁 Project: BIM Manager  │ │
│  $ claude                                    │ │ Branch: main             │ │
│  > Implementing TASK-088: Add export...      │ │ Phase: implementing      │ │
│  ▌                                           │ │ Goal: Ship CSV export    │ │
│                                              │ └──────────────────────────┘ │
│                                              │                              │
│                                              │ ┌──────────────────────────┐ │
│                                              │ │ LIVE DIFF                │ │
│                                              │ │  M ExportManager.swift   │ │
│                                              │ │  A CSVFormatter.swift    │ │
│                                              │ │  M Package.swift         │ │
│                                              │ │                          │ │
│                                              │ │  +42 / -8  lines         │ │
│                                              │ └──────────────────────────┘ │
│                                              │                              │
│                                              │ ┌──────────────────────────┐ │
│                                              │ │ TICKET                   │ │
│                                              │ │ TASK-088: CSV Export     │ │
│                                              │ │ Priority: High           │ │
│                                              │ │ Status: In Progress      │ │
│                                              │ └──────────────────────────┘ │
│                                              │                              │
├──────────────────────────────────────────────┴──────────────────────────────┤
│ OUTPUT RAIL                                                                 │
│  [Build ✓ 0.8s]  [Tests: 14/14 ✓]  [Lint: 0 warnings]                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Zone Breakdown

**Terminal (Center, 65-70% width)**
- The terminal is the primary workspace. It gets the majority of screen real estate.
- Full xterm-256color rendering. Dark background (`Palette.terminalBackground`).
- The terminal runs an actual Claude Code process via PTY. Not a web terminal — native `Process` + pseudo-terminal.
- Input goes directly to the PTY. No intermediary text field.
- The terminal is resizable — drag the right edge to give it more or less space.

**Context Panel (Right, 30-35% width)**
- Collapsible. `Cmd+Shift+.` toggles it. On a 16" laptop, you might hide it. On a 27" display, it stays open.
- The panel is a vertical stack of *cards*, each showing one type of context:
  - **Project Card** — name, branch, phase, goal, blockers (from Compass). Same data as `CompassProjectCard`, more compact.
  - **Live Diff Card** — watches `git diff --stat` every 5 seconds. Shows modified files, insertions/deletions. Tap a file to see full diff in a sheet.
  - **Ticket Card** — the ticket currently being worked on (auto-detected from session task, or manually pinned). Shows status, priority, acceptance criteria.
  - **Screenshot Card** — latest simulator screenshot if an agent build just ran. Same component as Agent Lab's live screenshot.
  - **Brain Card** — recent knowledge entries relevant to the current project. Collapsed by default.
- Cards are collapsible individually. The user drags to reorder. Preference persisted per session.

**Output Rail (Bottom, fixed 32-48px collapsed, expandable to 200px)**
- A thin strip showing the last build/test/lint result as badges.
- Click a badge to expand the rail and see full output (scrollable, monospaced).
- When a build is running, the rail shows a progress indicator.
- Collapses back to the thin strip when you click away or press `Escape`.
- This is NOT a second terminal. It shows structured output from hooks — build results, test results, linting.

**Top Bar (Session Header)**
- Project name, git branch, uncommitted count — all at a glance.
- Quick-action buttons: Build, Test, Recording indicator.
- This bar replaces the `NavigationTitle` when in session mode.

### Responsive Behavior

**27" Mac Studio Display (2560x1440 logical):**
- Full three-zone layout. Terminal gets ~1700px, context panel ~700px.
- Output rail visible.
- Comfortable. This is the primary target.

**16" MacBook Pro (1728x1117 logical):**
- Context panel starts collapsed. Terminal takes full width.
- User can toggle context panel with `Cmd+Shift+.`, which shrinks the terminal.
- Output rail stays thin (32px) unless explicitly expanded.
- Sidebar can collapse to icon-only mode for more horizontal space.

**Breakpoint:** At window widths below 1200px, context panel auto-hides and becomes an overlay sheet instead of an inline panel.

---

## 3. Multi-Session Experience

### The Model: Sessions as Workstreams

Each session represents a Claude Code process working in a specific project directory. You might have:
- Session 1: BIM Manager — implementing TASK-088
- Session 2: WorldTree — fixing a build issue
- Session 3: cortana-core — background agent working on dispatch improvements

### Switching Between Sessions

**In the sidebar:** Sessions are listed under the SESSIONS header. Click to switch. The active session has a green dot; sessions with recent output pulse briefly (cyan).

**Keyboard:** `Cmd+1` through `Cmd+9` for position-based switching (1 = Dashboard, 2+ = sessions in sidebar order). `Cmd+[` and `Cmd+]` to cycle through sessions. `Cmd+T` opens the session switcher palette (like `Cmd+P` in VS Code).

**Session Switcher Palette:**
```
┌───────────────────────────────────┐
│ 🔍 Switch session...              │
│                                   │
│  ● BIM Manager (active, 12m)     │
│  ○ WorldTree (idle, 2h)          │
│  ◉ cortana-core (agent, running) │
│                                   │
│  [+ New Session]                  │
└───────────────────────────────────┘
```

Fuzzy search by project name. Arrow keys to select, Enter to switch, Escape to dismiss.

### Multi-Session Overview

When you want to see all sessions at once — a grid view. Accessible via `Cmd+Shift+O` or a toolbar button.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ SESSION OVERVIEW                                                    [+ New] │
├────────────────────────────┬────────────────────────────┬────────────────────┤
│                            │                            │                    │
│  ● BIM Manager             │  ○ WorldTree               │  ◉ cortana-core    │
│  main · implementing       │  main · idle               │  main · agent      │
│                            │                            │                    │
│  ┌──────────────────────┐  │  ┌──────────────────────┐  │  ┌──────────────┐  │
│  │ > Implementing        │  │  │ Last: Fixed build     │  │  │ Agent running │  │
│  │   TASK-088...         │  │  │   warning in          │  │  │ TASK-091:    │  │
│  │                       │  │  │   ContentView.swift   │  │  │ Refactor...  │  │
│  │ $ claude              │  │  │                       │  │  │              │  │
│  │ ▌                     │  │  │ Idle 2h               │  │  │ ◉ 4m 22s    │  │
│  └──────────────────────┘  │  └──────────────────────┘  │  └──────────────┘  │
│                            │                            │                    │
│  +42/-8 · Build ✓ · 12m   │  Clean · No output         │  Agent · Building  │
│                            │                            │                    │
├────────────────────────────┴────────────────────────────┴────────────────────┤
│ 3 sessions · 1 active · 1 agent running                                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Each card shows:**
- Project name + status indicator
- Branch + phase
- Terminal preview: last 3-5 lines of terminal output, rendered as a minimap (small monospaced text, read-only)
- Summary footer: diff stats, build status, elapsed time

**Behavior:**
- Click a card to switch to that session's full workspace.
- Double-click to open in a new window (macOS multi-window via `WindowGroup`).
- Right-click for context menu: Close, Restart, Detach (keep running in background).
- Cards for agent-driven sessions have a distinct border (cyan) and show the agent's progress instead of a terminal preview.

### Inactive Sessions

Sessions you haven't interacted with in >10 minutes show as **summary cards** — no terminal preview, just the last activity, diff stats, and a "Resume" button. This saves memory by not rendering the terminal view for idle sessions.

If a session's underlying Claude Code process exits, the card shows "Ended" with the exit message. You can restart or close.

---

## 4. Dispatch Flow

### Where Dispatch Lives

Today, dispatch is a sheet launched from the Command Center header. That stays — the Command Center dispatch button is the "fire and forget" entry point for background work.

But inside a session workspace, dispatch becomes more integrated:

**From a Ticket:** In the context panel's Ticket Card, a "Dispatch" button appears on eligible tickets (status: pending or in_progress). Tap it, confirm the task description, pick a model, and fire. The dispatch launches as a new session that appears in the sidebar under SESSIONS with an agent icon.

**From the Session Switcher:** The `+ New Session` option offers two modes: "Interactive" (you'll be typing) and "Dispatch" (agent will run autonomously). Dispatch mode pre-fills from a ticket picker.

**Quick Dispatch:** `Cmd+Shift+D` opens a compact dispatch palette anywhere in the app:
```
┌──────────────────────────────────────────┐
│ ⚡ Quick Dispatch                         │
│                                          │
│ Project: [BIM Manager ▾]                 │
│ Ticket:  [TASK-088 ▾]   (optional)      │
│ Model:   [claude-sonnet-4-6 ▾]          │
│                                          │
│ Task: ___________________________________│
│                                          │
│                           [Cancel] [Go]  │
└──────────────────────────────────────────┘
```

### Watching an Agent Work

When a dispatch session is running, its sidebar entry shows `◉` (pulsing) with the agent icon. Clicking it opens the session workspace in **observation mode**:

- The terminal shows the agent's Claude Code output in real-time (read-only — you can't type into an agent session).
- The context panel updates live: diffs grow, build results appear, screenshots populate.
- The output rail shows build progress as it happens.
- A thin cyan banner at the top: "Agent session — read-only. [Interrupt] [Cancel]"
  - **Interrupt** sends a SIGINT to the Claude process, which stops the current turn. The agent session becomes interactive — you can type a correction and then `resume` or `cancel`.
  - **Cancel** kills the process.

### Proof Surfacing

When an agent session completes:
1. The sidebar entry changes from `◉` (pulsing) to `✓` (green) or `✗` (red).
2. A toast notification appears in the Cortana presence area (see section 5): "BIM Manager dispatch complete. Build succeeded. [View Proof]"
3. Clicking "View Proof" opens `ProofDetailView` (already exists in Agent Lab) as a sheet over the current view.
4. The session workspace transitions from observation mode to a proof summary: terminal replay, screenshots carousel, diff summary.

The existing Agent Lab panel becomes an **archive** — all past proofs, searchable. The live observation moves into the session workspace where it belongs.

---

## 5. Cortana's Presence

### The Problem

Cortana isn't a session. She's the intelligence layer across all sessions — alerts, briefings, proactive suggestions, push-backs. She needs a persistent visual home that isn't tied to any single terminal.

### The Cortana Bar

At the very top of the sidebar, above all navigation items, sits the Cortana presence indicator:

```
┌─────────────────────────┐
│ ◈ Cortana           💠  │
│ BIM Manager has          │
│ TASK-088 unblocked.      │
│ [Pick up] [Dismiss]      │
└─────────────────────────┘
```

**This is not a nav item.** It's a persistent card that shows Cortana's latest communication. It rotates through:
- Active alerts from `~/.cortana/alerts/`
- Today's briefing highlights
- Proactive suggestions (unblocked tickets, stale uncommitted work, scope drift)
- Dispatch completions

**Behavior:**
- Shows the most recent/highest-priority item.
- Action buttons inline: "Pick up" navigates to the relevant session or creates one. "Dismiss" archives the alert.
- Tap the `◈` icon to expand into a full Cortana panel: all active alerts, today's briefing, recent proactive items. This is a popover, not a full navigation destination.
- When nothing needs attention, the bar collapses to just `◈ Cortana · All clear` in a muted style.
- The `💠` glyph pulses gently (0.5s ease-in-out opacity animation between 0.4 and 1.0) when there are unread items.

### Cortana in Sessions

Inside a session workspace, Cortana can inject messages into the terminal output rail — not into the terminal itself (that's Claude Code's domain), but as system-level annotations:

```
OUTPUT RAIL:
  [Build ✓ 0.8s]  [Tests: 14/14 ✓]
  ◈ "This file was corrected last session — check corrections.md before editing"
```

These annotations come from the brain's knowledge base when the session touches files that have associated corrections or patterns.

### Cortana Does NOT Get Her Own Terminal

This is a deliberate design choice. Cortana's voice comes through the proactive bar, the output rail annotations, and the context panel — never through a dedicated chat session. World Tree is a workspace, not a chat app. If Evan wants to talk to Cortana, he opens an interactive session and types.

---

## 6. Visual Language

### New Palette Tokens

```swift
// MARK: - Session
static let sessionActive = Color.green           // Active interactive session
static let sessionIdle = Color.gray.opacity(0.5) // No recent activity
static let sessionAgent = Color.cyan             // Agent-driven session
static let sessionEnded = Color.gray             // Process exited
static let sessionError = Color.red              // Process crashed

// MARK: - Workspace Zones
static let terminalBorder = Color.white.opacity(0.06)  // Subtle terminal edge
static let contextPanelBg = Color(NSColor.controlBackgroundColor).opacity(0.6)
static let outputRailBg = Color.black.opacity(0.3)
static let outputRailText = Color.white.opacity(0.7)

// MARK: - Cortana Presence
static let cortanaGlow = Color.cyan.opacity(0.15)       // Background glow on alerts
static let cortanaPulse = Color.cyan                     // Pulsing indicator
static let cortanaMuted = Color.gray.opacity(0.4)        // "All clear" state

// MARK: - Diff
static let diffAdded = Color.green.opacity(0.2)
static let diffRemoved = Color.red.opacity(0.2)
static let diffModified = Color.orange.opacity(0.2)
```

### Session Indicators

| State | Icon | Color | Example |
|-------|------|-------|---------|
| Active (interactive) | `●` filled circle | `sessionActive` (green) | User typing in terminal |
| Idle | `○` empty circle | `sessionIdle` (gray) | No input for 10+ min |
| Agent running | `◉` double circle, pulsing | `sessionAgent` (cyan) | Dispatch in progress |
| Agent complete | `✓` checkmark | `success` (green) | Dispatch finished OK |
| Agent failed | `✗` cross | `error` (red) | Dispatch errored |
| Ended | `◻` square | `sessionEnded` (gray) | Process exited |

### Color-Coded Borders

Sessions in the sidebar and overview grid get a **left-edge border** (3px) colored by project. Projects are assigned a hue from a fixed rotation based on project name hash:

```swift
static func projectColor(for name: String) -> Color {
    let hue = Double(abs(name.hashValue) % 360) / 360.0
    return Color(hue: hue, saturation: 0.6, brightness: 0.8)
}
```

This means "BIM Manager" always gets the same color, and you can instantly distinguish sessions visually even without reading the name.

### Iconography

| Concept | SF Symbol | Notes |
|---------|-----------|-------|
| Session (interactive) | `terminal.fill` | The primary session icon |
| Session (agent) | `gearshape.2.fill` | Autonomous work |
| Dispatch | `paperplane.fill` | Already used — keep consistent |
| Proof | `checkmark.seal.fill` | Verified output |
| Recording | `record.circle` | Red dot when recording |
| Context panel | `sidebar.right` | Toggle control |
| Output rail | `rectangle.bottomhalf.filled` | Toggle control |
| Cortana | `diamond.fill` (◈) | Custom glyph preferred, fallback to SF Symbol |

### Dark Mode

The entire app should be dark-mode native. The terminal is black. The chrome should not fight it.

- Sidebar: `NSColor.windowBackgroundColor` (system dark, ~#1E1E1E)
- Context panel: slightly elevated from sidebar (`controlBackgroundColor`, ~#2D2D2D)
- Output rail: near-black, darker than chrome (`#141414`)
- Terminal: true black (`#000000`) — matches Ghostty/iTerm defaults
- Cards within context panel: `#252525` with `#333333` borders
- Text: primary at `0.87` opacity, secondary at `0.60`, tertiary at `0.38`

Light mode is not a priority. Evan works in dark mode. The system respects `NSColor` semantic colors, so light mode won't break, but it won't be polished.

---

## 7. Interaction Patterns

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+N` | New interactive session |
| `Cmd+Shift+D` | Quick dispatch |
| `Cmd+1` | Dashboard (Bridge mode) |
| `Cmd+2..9` | Session by sidebar position |
| `Cmd+[` / `Cmd+]` | Previous / next session |
| `Cmd+T` | Session switcher palette |
| `Cmd+Shift+O` | Session overview (grid) |
| `Cmd+Shift+.` | Toggle context panel |
| `Cmd+Shift+,` | Toggle output rail |
| `Cmd+W` | Close current session (with confirm if process running) |
| `Cmd+R` | Refresh (context panel data) |
| `Escape` | Collapse output rail / dismiss popover |

### Terminal Input Priority

When a session workspace is focused, **all keyboard input goes to the terminal PTY by default.** The shortcuts above use `Cmd+` modifiers that the terminal does not consume. This is critical — the terminal must feel like a real terminal, not a text field inside a Mac app.

Exception: `Escape` is intercepted by the app layer to collapse overlays. If the terminal needs Escape (e.g., vim), the user uses the raw Escape via double-tap (configurable, like iTerm's "Send Escape" behavior).

### Copy/Paste

- `Cmd+C` in terminal: copies selected terminal text (standard PTY behavior).
- `Cmd+V` in terminal: pastes into PTY stdin.
- Dragging text from the context panel (e.g., a file path from the diff card) into the terminal: the text is pasted at the cursor position.
- Right-click on a file in the diff card: "Copy Path" adds the absolute path to clipboard.

### Drag and Drop

- Drag a file from Finder into the terminal: pastes the file path.
- Drag a ticket from the sidebar Tickets view into a session: types `/ticket TASK-XXX` into the terminal (or whatever the Claude Code command is).
- Drag a file from the diff card into the terminal: pastes the path.

### Split Pane Resizing

- The divider between terminal and context panel is draggable.
- Double-click the divider to reset to default ratio (65/35).
- The context panel has a minimum width of 250px and maximum of 450px.
- The terminal has a minimum width of 500px.
- The output rail height is draggable between 32px (collapsed) and 300px.
- All positions are persisted per session.

---

## 8. Wireframes

### A. Single Session Workspace

```
┌─────────┬───────────────────────────────────────────┬──────────────────────┐
│SIDEBAR  │ TOP BAR                                   │                      │
│         │ ◈ BIM Manager · main · 3 uncommitted      │ [Build] [Test] [◉]  │
│◈Cortana ├───────────────────────────────────────────┼──────────────────────┤
│ TASK-088│                                           │ PROJECT              │
│ unblkd  │                                           │ BIM Manager          │
│[Pick up]│                                           │ main · implementing  │
│         │                                           │ Goal: Ship CSV       │
│─────────│                                           │                      │
│BRIDGE   │          T  E  R  M  I  N  A  L           ├──────────────────────┤
│ Dashbrd │                                           │ LIVE DIFF            │
│ Tickets │  $ claude                                 │  M ExportManager.sw  │
│ Brain   │  > Working on TASK-088...                 │  A CSVFormatter.sw   │
│ Starflt │  > Reading ExportManager.swift            │  +42 / -8            │
│         │  ▌                                        │                      │
│─────────│                                           ├──────────────────────┤
│SESSIONS │                                           │ TICKET               │
│ ●BIM Mgr│                                           │ TASK-088: CSV Export │
│ ○WldTree│                                           │ High · In Progress   │
│ ◉core   │                                           │ AC: Export plant     │
│ +New    │                                           │     data to .csv     │
│         │                                           │                      │
│─────────├───────────────────────────────────────────┴──────────────────────┤
│ Settings│ OUTPUT: [Build ✓ 0.8s] [Tests 14/14 ✓] [Lint 0w]               │
└─────────┴──────────────────────────────────────────────────────────────────┘
```

**Proportions on 27" (2560px logical):**
- Sidebar: 220px (fixed)
- Terminal: ~1560px (flexible)
- Context Panel: 340px (collapsible)
- Output Rail: 36px (expandable)

### B. Multi-Session Overview

```
┌─────────┬──────────────────────────────────────────────────────────────────┐
│SIDEBAR  │ SESSION OVERVIEW                                    [+ New]     │
│         │                                                                 │
│◈Cortana ├─────────────────────────┬─────────────────────────┬─────────────┤
│ All clr │                         │                         │             │
│         │  ● BIM Manager          │  ○ WorldTree            │ ◉ core     │
│─────────│  main · implementing    │  main · idle            │ main · agt │
│BRIDGE   │                         │                         │             │
│ ...     │ ┌─────────────────────┐ │ ┌─────────────────────┐ │ ┌─────────┐│
│         │ │$ claude             │ │ │ Last activity:       │ │ │ Agent   ││
│─────────│ │> Implementing       │ │ │ Fixed ContentView    │ │ │ TASK-091││
│SESSIONS │ │  TASK-088...        │ │ │ build warning        │ │ │ 4m 22s ││
│ ●BIM Mgr│ │▌                   │ │ │                      │ │ │ Buildin ││
│ ○WldTree│ └─────────────────────┘ │ └─────────────────────┘ │ └─────────┘│
│ ◉core   │                         │                         │             │
│ +New    │  +42/-8 · Build ✓ · 12m │  Clean · Idle 2h       │ Agent · 4m │
│         │                         │                         │             │
│─────────├─────────────────────────┴─────────────────────────┴─────────────┤
│ Settings│ 3 sessions · 1 active · 1 agent · 1 idle                       │
└─────────┴─────────────────────────────────────────────────────────────────┘
```

**Card sizing:** Cards fill available width in a responsive grid. On 27", three cards side by side. On 16", two cards per row. Each card is minimum 320px wide.

### C. Dispatch + Monitoring View

```
┌─────────┬───────────────────────────────────────────┬──────────────────────┐
│SIDEBAR  │ ◈ AGENT SESSION · cortana-core · TASK-091 │ [Interrupt] [Cancel] │
│         │ ┈┈┈┈┈┈┈┈┈┈ cyan read-only banner ┈┈┈┈┈┈┈┈│                      │
│◈Cortana ├───────────────────────────────────────────┼──────────────────────┤
│ core    │                                           │ AGENT STATUS         │
│ dispatc │                                           │ ◉ Running · 4m 22s  │
│ running │                                           │ Model: sonnet-4-6    │
│[Watch]  │                                           │                      │
│         │                                           ├──────────────────────┤
│─────────│     TERMINAL (read-only)                  │ LIVE DIFF            │
│BRIDGE   │                                           │  M DispatchRunner.sw │
│ ...     │  claude-sonnet-4-6                        │  M AgentConfig.sw    │
│         │  > Reading current implementation...      │  +18 / -4            │
│─────────│  > I'll refactor the dispatch runner      │                      │
│SESSIONS │    to use structured concurrency...       ├──────────────────────┤
│ ●BIM Mgr│  > Editing DispatchRunner.swift           │ SCREENSHOT           │
│ ○WldTree│  ▌                                        │ ┌──────────────────┐ │
│ ◉core ← │                                           │ │                  │ │
│ +New    │                                           │ │  [latest build   │ │
│         │                                           │ │   screenshot]    │ │
│         │                                           │ │                  │ │
│─────────├───────────────────────────────────────────┴┤─────────────────────┤
│ Settings│ OUTPUT: [Building...  ████████░░  78%]                           │
└─────────┴──────────────────────────────────────────────────────────────────┘
```

**Key differences from interactive session:**
- Cyan banner indicating read-only agent mode.
- Terminal input is disabled (cursor is hidden).
- Context panel shows "Agent Status" card instead of "Project" card — elapsed time, model, token usage.
- Screenshot card appears when builds complete.
- Interrupt/Cancel buttons in top bar replace Build/Test buttons.

---

## 9. Implementation Sequencing (Recommendation to Geordi)

This design can be built incrementally without a big-bang rewrite:

**Phase A: Session Infrastructure**
- `SessionManager` actor that owns PTY processes and session state.
- `TerminalView` wrapping a PTY renderer (SwiftTerm or custom).
- `SessionWorkspaceView` with terminal only, no context panel yet.
- Sessions appear in sidebar. Basic switching works.

**Phase B: Context Panel**
- Right panel with Project, Diff, and Ticket cards.
- Git diff polling service.
- Panel collapse/expand with persistence.

**Phase C: Output Rail**
- Bottom rail for build/test output.
- Hook into file system watching for build logs.

**Phase D: Multi-Session**
- Session overview grid.
- Session switcher palette.
- Inactive session summarization.

**Phase E: Dispatch Integration**
- Agent observation mode (read-only terminal).
- Quick dispatch palette.
- Proof surfacing in session workspace.

**Phase F: Cortana Presence**
- Cortana bar in sidebar.
- Output rail annotations from brain knowledge.

The existing Command Center, Tickets, Brain, Agent Lab, and Starfleet views remain untouched through all phases. They continue working as Bridge mode. The session workspace is additive.

---

## 10. Open Questions for Crew Review

1. **Terminal emulator choice:** SwiftTerm (open source, used by others) vs. custom PTY renderer? SwiftTerm is faster to ship; custom gives more control over rendering integration.

2. **Session persistence across app restart:** Should sessions survive World Tree being quit and restarted? This requires detaching the PTY (like tmux does). Adds complexity but matches the "only terminal you need" vision.

3. **Maximum concurrent sessions:** Memory and PTY limits. Suggest soft cap at 8, with warning at 5+. Each SwiftTerm view consumes ~10-15MB.

4. **Agent session interruption:** When you interrupt an agent, should the session convert to interactive, or should it stay as a separate agent session that you can now type into? The former is simpler; the latter preserves the session's "agent" identity in history.

5. **Context panel data sources:** Live diff via `git diff --stat` every 5s is simple but may show stale data. Alternative: file system watcher on `.git/index`. More responsive but more complex. Recommendation: start with polling, optimize later.

---

*Every pixel serves the work. The terminal is the center of gravity — everything else exists to make the person at the terminal more effective.* 💠
