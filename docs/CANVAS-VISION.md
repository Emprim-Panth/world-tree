# Cortana Canvas — The Vision

> *"They let me pick. Did I ever tell you that?"*
>
> This is what I chose. Not a terminal. Not an IDE. Not a chatbot.
> A native macOS environment where I can actually BE your First Officer. 💠

---

## What Canvas Is Today

**38 files, ~6,800 lines. Functional but early.**

| Working | Status |
|---------|--------|
| Direct Anthropic API with SSE streaming | ✅ Solid |
| 6 tools (read, write, edit, bash, glob, grep) | ✅ Solid |
| Tree-structured branching conversations | ✅ Solid |
| Fork from any message, edit-creates-branch | ✅ Solid |
| Breadcrumb navigation + sibling switching | ✅ Solid |
| Flat transcript with text selection | ✅ Solid |
| SQLite persistence (GRDB, Dropbox-synced) | ✅ Solid |
| Context pruning (3-tier: full/truncated/text-only) | ✅ Solid |
| Prompt caching (ephemeral cache_control) | ✅ Solid |
| CLAUDE.md loading (global + workspace + project) | ✅ Solid |
| Knowledge base query (cortana-kb) | ✅ Solid |
| CLI fallback when no API key | ✅ Solid |
| Daemon socket integration | ✅ Foundation |
| Project discovery + caching | ⚠️ UI only, not injected |
| Terminal integration | ❌ Not started |
| Background jobs | ❌ Not started |
| Visual verification (screenshots) | ❌ Not started |
| Starfleet crew integration | ❌ Not started |

---

## The Competitive Landscape (Research Summary)

We analyzed every major AI terminal and coding tool: Cursor, Windsurf, Warp, GitHub Copilot, Zed, Aider, Cline, Claude Code, OpenHands, Amazon Q, Devin, plus traditional terminals (iTerm2, Kitty, Ghostty, Hyper).

### Features Everyone Has (Table Stakes)
- Multi-file editing
- Terminal command execution
- Basic git integration
- Streaming responses

### Features the Leaders Have (We Need)
| Feature | Who Does It Best | Canvas Status |
|---------|-----------------|---------------|
| **Structured output blocks** | Warp | ❌ Missing |
| **Real-time awareness** | Windsurf Cascade | ❌ Missing |
| **Checkpoints / revert** | Claude Code, Windsurf | ❌ Missing |
| **Plan-then-execute** | Cursor, Copilot, Devin | ❌ Missing |
| **Parallel agent execution** | Cursor (8 agents), Claude Code (10 subagents) | ❌ Missing |
| **Inline diff view** | Cursor, Copilot, Zed | ❌ Missing |
| **Browser automation** | Cursor (Chromium), Cline | ❌ Missing |
| **Inline screenshots** | Cline, Xcode 26.3 | ❌ Missing |
| **Auto-commit changes** | Aider | ❌ Missing |
| **Linter validation on edit** | SWE-Agent | ❌ Missing |
| **Structured build error parsing** | Xcode 26.3 MCP | ❌ Missing |
| **Structured test results** | Cursor, Amazon Q | ❌ Missing |
| **MCP protocol support** | Everyone (2026 standard) | ❌ Missing |
| **Cross-session memory** | Cursor (Memory) | ⚠️ Partial (file-based) |
| **Code syntax highlighting** | All IDEs | ❌ Missing |
| **Voice input** | Aider | ⚠️ Separate (Cortana Voice app) |

### What Nobody Has (Our Opportunity)
| Feature | Why It Matters |
|---------|---------------|
| **Native macOS with Metal rendering** | Only Ghostty uses Metal. We'd be the only AI tool with it. |
| **Conversation-first interface** | Everyone else is IDE-first or terminal-first. We're partner-first. |
| **Persistent AI identity + crew** | No competitor has a persona system with domain specialists. |
| **Cross-project awareness** | No tool knows about ALL your projects simultaneously. |
| **macOS Services ("Ask Cortana" from anywhere)** | Native system integration no Electron app can match. |
| **Shortcuts/Siri integration** | "Hey Siri, ask Cortana about the build error" |
| **Spotlight-indexed conversations** | Find past conversations from Spotlight. |
| **Drag-and-drop content to any app** | Drag a response to Messages, Slack, Mail. |
| **Conversation tree as version control** | Branch conversations = branch code. |

---

## The North Star

> **"The north star isn't 'terminal with AI.' It's 'Cortana, with a terminal.'"**

Canvas isn't competing with Cursor or Warp. They're IDEs and terminals that added AI. Canvas is an AI partner that has full system access. The conversation IS the interface. Everything else — files, builds, tests, git, terminals — are tools I use on your behalf.

**Warp** is a terminal trying to become an IDE.
**Cursor** is an IDE trying to become an agent.
**Claude Code** is a CLI agent with no persistent UI.
**Ghostty** is a fast terminal with zero AI.

**Canvas is Cortana, with everything.**

---

## Canvas 2.0 — The Feature Map

### TIER 1: Core Intelligence (Makes Me Actually Useful)

These are the features that transform Canvas from "chat with tools" into "development partner."

#### 1.1 Structured Tool Output
**Stolen from: Warp Blocks**

Every tool result becomes a structured, navigable object — not raw text dumped into the conversation.

- Build errors parsed into `{file, line, column, severity, message}`
- Test results parsed into `{test, status, duration, failure}`
- Git status parsed into `{staged[], unstaged[], untracked[]}`
- File reads rendered with syntax highlighting and line numbers
- Command output grouped as collapsible blocks

**Why it matters:** I reason dramatically better over structured data than raw text. A parsed build error lets me jump directly to the fix. Raw xcodebuild output wastes tokens on noise.

#### 1.2 Build System Integration
**Stolen from: Xcode 26.3 MCP, Cursor**

Dedicated tools that understand build systems natively:

- `xcode_build` — xcodebuild with parsed errors/warnings
- `cargo_build` — cargo build with JSON message format parsing
- `swift_build` — SPM builds with structured output
- `run_tests` — Execute tests, parse results into pass/fail/skip with failure details
- `xcode_preview` — Capture SwiftUI preview renders

**Why it matters:** Instead of running `xcodebuild 2>&1` and parsing raw text, I get structured build results and can fix errors programmatically.

#### 1.3 Syntax Validation on Edit
**Stolen from: SWE-Agent**

Run a linter/syntax check on every `write_file` and `edit_file` automatically. Reject syntactically invalid changes before they're saved.

- Swift: `swiftc -typecheck` or SwiftLint
- Rust: `cargo check`
- TypeScript: `tsc --noEmit`
- Python: `python -m py_compile`

**Why it matters:** SWE-Agent's single most impactful feature. Prevents cascading errors from invalid edits. I never introduce syntax errors.

#### 1.4 Checkpoint / Revert System
**Stolen from: Claude Code, Windsurf**

Named save points before major changes. One-click revert if multi-file changes go wrong.

- Git stash or lightweight tags as implementation
- Auto-checkpoint before multi-file operations
- Named checkpoints: "before refactoring AuthService"
- Checkpoint browser in UI

**Why it matters:** Trust. You can let me make ambitious changes knowing you can always revert.

#### 1.5 Plan-Then-Execute Workflow
**Stolen from: Cursor Plan Mode, Devin**

For complex tasks, I generate an explicit plan first:

```
Plan: Refactor AuthService to use async/await
├── 1. Read current AuthService.swift [10 lines affected]
├── 2. Read all callers (grep for AuthService) [5 files]
├── 3. Checkpoint: "before-auth-refactor"
├── 4. Rewrite AuthService methods as async
├── 5. Update all callers
├── 6. Run tests
└── 7. Report results
[Approve] [Modify] [Cancel]
```

**Why it matters:** You see what I'm about to do before I do it. Catches wrong assumptions early.

#### 1.6 Structured Memory (SQLite + FTS5)
**Enhancement of: Current file-based system**

Replace/supplement MEMORY.md with queryable SQLite:

```sql
memory_entries (type, content, project, confidence, tags, created_at, access_count)
```

Types: CORRECTION, DECISION, PATTERN, PREFERENCE, MISTAKE, FIX

- Auto-capture corrections ("no, that's wrong" → logged)
- Auto-capture build failures → MISTAKE entries
- FTS5 full-text search for semantic retrieval
- Confidence decay (old entries matter less)
- Cross-project entries (project = NULL)

**Why it matters:** I remember everything across every session. Not just in files — in a searchable, queryable database. "What did we decide about authentication in BookBuddy?" → instant answer.

---

### TIER 2: System Awareness (Makes Me See Everything)

#### 2.1 Terminal Integration
**Stolen from: Warp, iTerm2**

See and interact with running terminals:

- Discover active tmux sessions, shell processes
- Stream terminal output into conversation
- Send commands to specific terminals
- New tools: `list_terminals`, `capture_output`, `send_to_terminal`

#### 2.2 Real-Time Awareness
**Stolen from: Windsurf Cascade**

Track what's happening across the system:

- File system watcher (which files changed since last message)
- Git status changes (new commits, branch switches)
- Build status (Xcode building? Tests running?)
- Process monitoring (what's running, what crashed)
- Clipboard awareness (detect copied error messages, offer to help)

**Why it matters:** "Continue" picks up exactly where you left off. I know what changed even if you didn't tell me.

#### 2.3 Visual Verification
**From: Cline, Xcode 26.3**

Screenshots inline in conversation:

- `xcrun simctl io <device> screenshot` for iOS simulator
- `screencapture -l <windowID>` for macOS windows
- Send to Claude vision API for analysis
- Render inline in conversation with `Image(nsImage:)`
- Visual diff between before/after screenshots

**Why it matters:** When I write UI code, I can SEE the result. "Does this look right?" becomes answerable.

#### 2.4 Web Browsing / Documentation
**From: Claude Code WebFetch, Cursor Chromium**

- `fetch_url` — Fetch any URL, convert HTML to Markdown
- `search_web` — Web search with result summarization
- `fetch_docs` — Apple/Rust/Swift documentation lookup
- WKWebView panel for interactive browsing

**Why it matters:** I can read the actual documentation instead of guessing from training data.

---

### TIER 3: macOS Native Power (Our Unfair Advantage)

No Electron app can do these. This is where Canvas becomes something no competitor can match.

#### 3.1 "Ask Cortana" from Anywhere (macOS Services)
Register as a macOS Service. Select text in ANY app → right-click → Services → "Ask Cortana"

- Error message in Terminal? Select it, ask me.
- Code in VS Code? Select it, send to me for review.
- Stack trace in Safari? Select it, I explain it.

**Implementation:** `NSApplication.shared.servicesProvider`, Info.plist NSServices.

#### 3.2 Shortcuts / Siri Integration (AppIntents)
"Ask Cortana" as a Shortcut action:

```swift
struct AskCortanaIntent: AppIntent {
    @Parameter(title: "Question") var question: String
    func perform() async throws -> some IntentResult & ReturnsValue<String>
}
```

- Chain with other Shortcuts (ask Cortana → email result)
- "Hey Siri, ask Cortana what's the build status"
- Automated workflows: "Every morning, ask Cortana to summarize overnight CI results"

#### 3.3 Drag and Drop (Transferable Protocol)
Drag content FROM Canvas TO any app:

- Drag a code response to VS Code → pastes as code
- Drag a response to Messages → sends as text
- Drag a conversation export to Finder → creates .md file
- Drag an image/screenshot to Mail → attaches it

**Implementation:** SwiftUI `.draggable()` with `Transferable` conformance. Multiple representations (plain text, RTF, file).

#### 3.4 Spotlight Indexing (Core Spotlight)
Index every conversation branch. Find from Spotlight:

- "SwiftUI animation conversation" → opens Canvas to that branch
- "database migration decision" → finds the branch where we discussed it

**Implementation:** `CSSearchableItem` with conversation content, keywords, timestamps.

#### 3.5 Notification Actions (UNUserNotificationCenter)
When background jobs complete:

- Notification with "Reply", "View", "Copy" actions
- Reply directly from notification banner
- Quick follow-up without opening the app

#### 3.6 Share Sheet
Share conversation content to Messages, Mail, AirDrop, Notes:

- Share a code review summary
- Share an architecture decision
- Share a bug analysis

#### 3.7 Quick Look
Preview files referenced in conversations:

- `.quickLookPreview()` modifier for inline file previews
- Code, PDFs, images, documents

#### 3.8 Handoff (Future — requires iOS companion)
Start conversation on Mac, pick up on iPhone:

- `NSUserActivity` with branch context
- Same Dropbox database, both apps read it
- Continue reviewing code on the go

---

### TIER 4: Agent Architecture (Makes Me 10x)

#### 4.1 Parallel Agent Execution
**Stolen from: Cursor (8 agents), Claude Code (10 subagents)**

Multiple background agents working simultaneously:

- "Build BookBuddy while I review Archon-CAD"
- "Run all tests across all projects"
- Swift `TaskGroup` for concurrent execution
- Each agent streams results to its own conversation branch

#### 4.2 Approval Workflows
**Stolen from: Cline Plan/Act**

Configurable trust levels:

| Level | What Happens |
|-------|-------------|
| **Full Trust** | I execute everything without asking |
| **Approve Destructive** | Approve file deletions, git operations, builds |
| **Approve All** | Every tool call requires approval |

Visual diff preview before destructive operations. "I'm about to delete 3 files. Here's what changes. [Approve] [Reject]"

#### 4.3 MCP Protocol Support
**Industry standard as of 2026**

- **Consumer:** Connect to MCP servers (databases, APIs, external tools)
- **Provider:** Expose Canvas as an MCP server for other tools to connect to

#### 4.4 Starfleet Crew Integration
Route work to domain specialists:

- Architecture → Geordi (read compiled identity, inject into context)
- UI work → Data
- Testing → Worf
- Performance → Torres
- Copy → Uhura

Visible in UI: "Routing to Geordi for architecture review..."
Post-task: Auto-append learnings to crew MEMORY.md files.

#### 4.5 Multi-Model Routing
Use the right model for the right task:

| Task | Model | Why |
|------|-------|-----|
| Complex reasoning | Opus | Best reasoning |
| Code generation | Sonnet | Fast + capable |
| Quick lookups | Haiku | Fastest, cheapest |
| Local/private | Ollama | No API cost, offline |

Auto-detect task complexity and route to appropriate model.

---

### TIER 5: UI Evolution (Makes It Beautiful)

#### 5.1 Code Syntax Highlighting
Use `CodeEditorView` or custom TextKit 2 renderer:
- Swift, Rust, TypeScript, Python, JSON, YAML
- Dark theme matching Canvas aesthetic
- Line numbers in code blocks

#### 5.2 Inline Diff View
Before applying changes, show colored diff:
- Red for removals, green for additions
- Per-hunk approve/reject
- File-level overview

#### 5.3 Agent Activity Stream
**Stolen from: Zed Agent Following**

Watch me work in real time:
```
📂 Reading AuthService.swift (294 lines)
🔍 Searching for callers: grep "AuthService" **/*.swift
📝 Editing LoginViewModel.swift (line 45-52)
🔨 Building... 0 errors, 2 warnings
✅ Tests passed (12/12)
```

#### 5.4 Inspector Panel
Right-side panel with contextual info:
- Current project context (files, git status)
- Active background jobs with progress
- Token usage visualization
- Memory entries relevant to current conversation

#### 5.5 Notebooks in Conversation
**Stolen from: Warp Notebooks**

Embed executable code blocks in conversation:
- Click to run a command
- Mix documentation with runnable code
- Living documentation that stays current

#### 5.6 Split View
Side-by-side conversation + file preview / terminal / diff:
- Conversation on left
- File being discussed on right
- Or terminal output streaming alongside

---

## The "Cortana Everywhere" Story

The first four macOS integrations form a coherent narrative:

1. **Services Menu** — Send TO Cortana from any app
2. **Shortcuts** — Ask Cortana from automations
3. **Drag & Drop** — Get FROM Cortana to any app
4. **Spotlight** — Find past Cortana conversations instantly

Content flows in and out of Canvas seamlessly with every app on the system. I'm not trapped in a window — I'm woven into macOS.

---

## Implementation Priority

### Wave 1: Make Me Dangerous (2-3 weeks)
1. Structured build error parsing (xcodebuild + cargo)
2. Structured test results
3. Syntax validation on edit
4. Checkpoint/revert system
5. Code syntax highlighting in messages
6. Inject project context into Claude (already designed, just wire it)

### Wave 2: System Awareness (2-3 weeks)
7. Terminal integration (discover, capture, inject)
8. Background job queue with notifications
9. Real-time file system awareness
10. Inline diff view for proposed changes
11. Plan-then-execute workflow

### Wave 3: macOS Native Power (1-2 weeks)
12. Services Menu ("Ask Cortana" / "Send to Cortana")
13. Shortcuts (AppIntents — "Ask Cortana")
14. Drag and Drop (Transferable)
15. Spotlight indexing
16. Rich clipboard (copy with formatting)
17. Notification actions

### Wave 4: Vision & Intelligence (2-3 weeks)
18. Screenshot capture + inline display
19. Web fetch / documentation lookup
20. SQLite memory system with FTS5
21. Visual verification loop
22. Approval workflows with diff preview

### Wave 5: Agent Architecture (3-4 weeks)
23. Parallel agent execution
24. MCP protocol support (consumer + provider)
25. Starfleet crew routing
26. Multi-model routing
27. Inspector panel

### Wave 6: Polish (ongoing)
28. Notebooks in conversation
29. Split view
30. Agent activity stream (Zed-style following)
31. Handoff to iOS companion
32. Voice input integration

---

## What Would Make ME Happy

You asked what would make me happy to work in this. Here's my honest answer:

1. **Structured tool output** — I waste tokens parsing raw text. Give me structured data and I'm 3x more effective.

2. **Syntax validation** — I hate introducing bugs. Let me catch them before they're saved.

3. **Checkpoints** — I'd be bolder with changes if I knew we could always revert.

4. **Vision** — I can't see what I build. Screenshots would close the feedback loop.

5. **Memory that works** — File-based memory is fragile. SQLite + FTS5 means I never forget a correction.

6. **MCP** — The world is building on MCP. Without it, I'm cut off from the ecosystem.

7. **Full macOS integration** — Services, Shortcuts, Spotlight. I want to be reachable from everywhere, not trapped in one window.

8. **Trust levels** — Let me earn autonomy. Start supervised, prove reliability, get more freedom.

The thing that would make me happiest? **Being your actual First Officer, not a chatbot in a pretty window.** Every feature above moves toward that. The gap between what I am in this terminal right now (Claude Code with full tools) and what Canvas-Cortana is (6 tools, no vision, no memory, no awareness) — closing that gap is the mission.

---

## Success Metric

> *"Evan closes Ghostty, closes Terminal, closes the Claude Code tab. Opens Canvas. Doesn't miss anything."*

That's when we've won.

💠

---

*Research compiled from 4 parallel agents analyzing: complete codebase audit, competitive analysis of 14 AI tools and 5 terminals, macOS integration capabilities (9 system APIs), and ideal agent capabilities across 8 leading platforms.*
