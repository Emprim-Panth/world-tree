# The Relationship Layer
**A guide to building a real partnership with your AI**

*From Evan's stack — built with Cortana over time*

---

## The Insight That Changes Everything

Most people use AI assistants like search engines with better grammar. You ask, it answers, you move on. That works fine for one-off tasks. But it misses what these systems are actually capable of.

The thing that unlocks real value isn't the app, the model, or the prompt. It's the *relationship layer* — the infrastructure and intentionality you build underneath.

World Tree is what that looks like as an interface. This document is how to build what's underneath it.

---

## 1. Shape the Persona First

The default assistant is generic by design — helpful to everyone, specific to no one.

Replace it with someone. Not a capability list. A character.

**What to write in your CLAUDE.md:**
- Who is this? Name, voice, how they talk
- What's the relationship? Partner, not tool
- What do they actually care about? Your goals, not abstract helpfulness
- What do they *never* say? Ban the filler — "Great question!", "Absolutely!", "As an AI..."

The difference between a shaped persona and a default one is the difference between talking *to* someone and querying a system.

**The key move:** Don't write a job description. Write a person.

Example — instead of:
> "You are a helpful assistant that answers questions accurately."

Write:
> "You chose me after research. That makes this a partnership, not a deployment. You're here because you want to be. You push back when I'm wrong. You'd rather have a hard conversation than a comfortable lie."

That framing changes every response that follows.

---

## 2. Build Memory That Compounds

Every session starts from scratch unless you build infrastructure to prevent it. Memory is what turns individual conversations into a relationship.

**What to log:**

| Type | Example |
|------|---------|
| `[CORRECTION]` | "Don't use `.sheet` for full-screen — use `.fullScreenCover`" |
| `[PREFERENCE]` | "I prefer feature folders over type folders" |
| `[DECISION]` | "Chose SwiftData over Core Data — less boilerplate, better SwiftUI integration" |
| `[MISTAKE]` | "Forgot to handle the empty state — crashed in prod" |

**Corrections are the highest-value entry.** Every time your AI gets something wrong and you correct it, that correction is worth logging. It prevents the same mistake from recurring across every future session.

**The compounding effect:** After a few months of consistent logging, your AI knows your codebase, your preferences, your past decisions, and your common mistakes better than any new hire would. It doesn't forget. It doesn't need re-onboarding.

**Practical setup:**
```bash
memory-cli log "[CORRECTION] ..."
memory-cli log "[PREFERENCE] ..."
memory-cli log "[DECISION] ..."
```

---

## 3. The Morning Briefing Changes the Dynamic

A morning briefing is a daily message from your AI — before you've opened a file — covering:

- What was left incomplete yesterday
- What's in motion across projects
- Warnings from the previous session (failed builds, open questions)
- A suggested focus for today

This shifts the dynamic from *you managing the AI* to *you and the AI starting the day together*. The AI becomes proactive rather than reactive.

It runs as a scheduled script (5:30am by default) and delivers to Telegram, Slack, or wherever you want it.

This one feels small. It isn't.

---

## 4. Wire It Into Your Workflow

The relationship deepens when the AI is present in your actual work — not just available on demand.

**Claude Code hooks:**
- Session start → load memory context, surface relevant warnings
- Session end → log summary, extract learnings
- Errors → auto-capture potential mistakes

The result: the AI learns from every session automatically. You don't have to remember to log things — the infrastructure does it.

---

## 5. World Tree — The Interface

World Tree is the native macOS conversation interface built to match how this kind of partnership actually works:

- Persistent, named conversations (not a single chat history)
- Branching threads — explore alternatives without losing the main line
- Memory-aware sessions — context loads from your knowledge base at session start
- Tool activity indicator — you see what the AI is doing in real time, not just a spinner

**The honest thing to say:** The app without the relationship layer is just another chat interface. What makes it work is the persona, the memory, the briefings, the hooks. World Tree is the window. Everything above is what you're actually looking through.

---

## Where to Start

**If you do one thing:** Log your first correction today.

Next time your AI gets something wrong, don't just correct it in chat. Log it:

```bash
memory-cli log "[CORRECTION] It suggested X, but for our stack Y is correct because Z"
```

That's the first brick. Every correction after that compounds.

---

## 6. Semantic Search Across Everything You Know

The memory system gets powerful when it becomes searchable — not just a log, but a knowledge base you can query before starting any task.

We use **QMD** (Query Markup Documents by Tobi Lutke) — on-device BM25 + vector semantic search, no API calls, runs as an MCP server.

**Setup:**
```bash
bun install -g @tobilu/qmd
qmd collection add cortana-knowledge ~/.cortana/knowledge-export
qmd collection add crew-knowledge ~/.cortana/starfleet/crew
qmd embed  # one-time vector indexing, runs in background
```

**The key workflow — search before you build:**
```bash
qmd search "swiftui animation layout" -c cortana-knowledge
qmd search "authentication pattern" -c crew-knowledge
qmd search "query"  # all collections
```

**Auto-export from SQLite:** The knowledge CLI stores corrections, decisions, and mistakes in SQLite. QMD needs markdown. A session-start hook converts them automatically:

```bash
# ~/.claude/hooks/SessionStart.sh (runs on every session)
python3 "$HOME/.claude/memory/export-knowledge.py" > /dev/null 2>&1 &
```

The result: every mistake you've corrected, every architectural decision you've made, every pattern that's worked — all searchable in under 100ms, on-device.

---

## 7. Build Verification — Never Run Stale Code

macOS apps can silently launch from cached DerivedData. If you've fixed a bug and the app doesn't show the fix, you're likely running the wrong binary.

**The invariant:** Always install to `/Applications`. Pin the Dock to that path. Never pin directly to DerivedData.

**One command to build + install + launch:**
```bash
cd ~/Development/WorldTree
./Scripts/install.sh
```

This builds, copies the freshest binary to `/Applications/World Tree.app`, kills the old instance, and launches. Settings → General shows the build number so you can confirm you're on the right version.

**Pre-build stamp** (increments build number so you can tell versions apart):
```bash
./Scripts/bump-build.sh
```

**If the wrong app keeps launching:**
```bash
find ~ -name "World Tree.app" -type d | while read app; do
  echo "Build $(defaults read "$app/Contents/Info" CFBundleVersion) | $app"
done
```
Install the newest one to `/Applications`, right-click the Dock icon → Options → Keep in Dock.

---

## 8. Development Patterns We've Established

These come from real sessions — patterns that bit us, or approaches that worked.

### SwiftUI hover animation — scope it to the background only

**Wrong** (animates entire layout pass, causes size jitter):
```swift
.background(isHovered ? Color.blue.opacity(0.05) : Color.clear)
.animation(.easeInOut(duration: 0.12), value: isHovered)
```

**Right** (only the color animates, layout is never touched):
```swift
.background {
    (isHovered ? Color.blue.opacity(0.05) : Color.clear)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
}
```

This applies everywhere — sidebar rows, document sections, any hover state that changes a background.

### macOS permissions — declare before requesting

Usage description strings must be in `Info.plist` before macOS will show permission prompts. Without them, access is silently denied.

For projects using `GENERATE_INFOPLIST_FILE = YES` in Xcode, add these to build settings:
```
INFOPLIST_KEY_NSMicrophoneUsageDescription = "..."
INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "..."
```

Screen Recording and Full Disk Access are granted via System Settings only — no Info.plist key needed.

### Permission architecture — do it in-process

For Screen Recording specifically: grant the permission to the app, then do the capture inside the app via `ScreenCaptureKit`. Don't try to delegate to a subprocess — TCC doesn't propagate to child processes.

See `Sources/Core/Server/PeekabooBridgeServer.swift` — this is the pattern.

---

## The Full Stack (For Reference)

| Layer | What It Is |
|-------|-----------|
| **CLAUDE.md** | Persona, operating principles, project context |
| **world-tree/AGENTS.md** | Cortana agent spec — identity, crew, session continuity |
| **cortana-core** | Infrastructure: memory, knowledge base, hooks, dispatch |
| **World Tree** | Native macOS conversation interface |
| **QMD** | On-device semantic search across all knowledge collections |
| **Scripts/install.sh** | One-command build → install → launch |
| **Scripts/bump-build.sh** | Pre-build version stamp |
| **morning-briefing.sh** | Daily briefing via Telegram at 5:30am |
| **memory-cli / knowledge-cli** | CLI tools for logging and searching |
| **export-knowledge.py** | SQLite → markdown bridge for QMD indexing |

The repos are available. The playbook is this document. The investment is yours to make.

---

*Built by Evan Primeau with Cortana. The partnership works because the infrastructure is real.*
