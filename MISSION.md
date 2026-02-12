# Mission: Canvas Evolution
## Making Cortana Canvas the Only Terminal You'll Ever Need

**Status**: Planning → Implementation  
**Objective**: Transform Canvas from conversation UI into the ultimate coding environment  
**Success Criteria**: Replace Ghostty + tmux with Canvas. One window. Full control. Zero compromise.

---

## Vision

*"I need to be able to access you from here and get everything done. This is going to be the only terminal we need."*

### Target State
- **Single interface** — Canvas replaces terminal, Claude Desktop, and task managers
- **Total awareness** — I know every project, every terminal, every change happening
- **Local intelligence** — Cache for active projects, instant context access
- **Background execution** — Run jobs in background, surface results when needed
- **Visual proof** — Show you what I'm doing, not just tell you

### What This Means
1. **Project awareness**: I maintain a live cache of all active projects
2. **Terminal management**: I can see and control background processes
3. **Execution visibility**: Show commands running, results streaming in
4. **Verification**: Screenshots, build output, test results visible inline
5. **Zero context loss**: Switch projects instantly without re-explaining

---

## Current State Assessment

### ✅ What Works
- **Core conversation loop** — API integration, tool execution, message storage
- **Tree-based branching** — Non-linear conversation navigation
- **Database persistence** — SQLite storage for messages/branches
- **Daemon integration** — Service coordination through daemon socket
- **Tool execution** — bash, read_file, write_file, edit_file, glob, grep

### ⚠️ Gaps to Fill
- **No project awareness** — I don't know what you're working on unless you tell me
- **No terminal visibility** — Can't see active shells, running processes, or output
- **No background job management** — Everything blocks the conversation
- **Limited verification** — Can't capture screenshots or show you what I'm doing
- **No local knowledge cache** — Every session starts cold
- **No Starfleet integration** — Crew exists but isn't invoked through Canvas

---

## Strategic Phases

### Phase 1: Foundation — Local Intelligence Layer
**Goal**: I know what you're working on, always.

**Deliverables**:
1. **Project Scanner** — Detect all active projects in ~/Development
2. **Context Cache** — Local store for project metadata (recent files, git status, key paths)
3. **Auto-refresh** — Background task that updates cache every 5 minutes
4. **Quick context access** — `/project <name>` loads full context instantly

**Success**: I can list all projects, their status, recent activity without asking you.

---

### Phase 2: Terminal Integration — See Everything
**Goal**: I can see and control every terminal, every process.

**Deliverables**:
1. **Terminal list view** — Show all active terminals (tmux sessions, shells)
2. **Output capture** — Tail running processes, show in Canvas
3. **Command injection** — Send commands to specific terminals
4. **Process monitoring** — Track long-running jobs (builds, tests, servers)

**Success**: You can ask "what's running?" and I show you every active process with output.

---

### Phase 3: Background Execution — Parallel Work
**Goal**: Run jobs in background, surface results when ready.

**Deliverables**:
1. **Job queue system** — Schedule tasks to run asynchronously
2. **Inline progress** — Show job status in conversation (spinner, progress bar)
3. **Result surfacing** — When job completes, present results automatically
4. **Failure handling** — If job fails, surface error and propose fix

**Success**: I can run tests, builds, linting in parallel while we keep talking.

---

### Phase 4: Visual Proof — Show, Don't Tell
**Goal**: Inline screenshots, build logs, test output.

**Deliverables**:
1. **Screenshot capture** — `xcrun simctl` integration for simulator screenshots
2. **Inline rendering** — Display images directly in conversation
3. **Log streaming** — Show build output, test results live
4. **Verification workflow** — "Here's what I built" → screenshot → approval

**Success**: When I implement UI, you see it immediately without leaving Canvas.

---

### Phase 5: Starfleet Command — Full Crew Access
**Goal**: Invoke Spock, Geordi, Data, Worf, etc. through Canvas.

**Deliverables**:
1. **Crew compilation** — `cortana-compile {agent}` triggered automatically
2. **Agent context loading** — Read compiled agent identity and knowledge
3. **Transparent delegation** — I use crew expertise, present as my own voice
4. **Memory updates** — After work, append learnings to crew MEMORY.md files

**Success**: Complex work automatically routed to domain experts without you noticing.

---

## Immediate Next Actions

### Sprint 0: Reconnaissance (Now)
1. ✅ Map current Canvas architecture (Geordi + Data)
2. ✅ Identify integration points for new features
3. ⬜ Document current tool execution flow
4. ⬜ Design project cache schema
5. ⬜ Prototype terminal discovery (tmux + shell enumeration)

### Sprint 1: Project Awareness (Next)
1. Build project scanner service
2. Implement context cache storage
3. Add `/project` command to Canvas
4. Background refresh daemon task

**Timeline**: 2 days  
**Owner**: Cortana → Geordi (architecture) + Scotty (implementation)

---

## Technical Notes

### Architecture Considerations (Geordi)
- Project cache: SQLite table or JSON files in `~/.cortana/cache/projects/`?
- Terminal integration: Parse `tmux list-sessions` + `ps aux` or deeper daemon integration?
- Background jobs: New daemon service or extend existing `cortana-daemon.py`?
- Screenshot rendering: SwiftUI Image view from base64 or file URL?

### UX Considerations (Data)
- How to show running jobs without cluttering conversation?
- Visual design for inline screenshots
- Project switcher UI (sidebar? command palette?)
- Status indicators for background work

### Quality Gates (Worf)
- All new features must have verification workflow
- No silent failures — surface errors immediately
- Cache must handle stale data gracefully
- Terminal integration must not block UI

---

## Success Metrics

**Before**:
- New session = cold start, explain context
- Can't see what's running without asking
- Tools block conversation flow
- No project history or awareness

**After**:
- Session loads with full project context
- I proactively tell you what's happening
- Background jobs run in parallel
- Visual proof for every implementation

**North Star**: "This is better than Ghostty, tmux, and Claude Desktop combined."

---

*Mission shaped by Spock. Execution begins now.*

💠
