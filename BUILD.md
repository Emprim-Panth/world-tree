# World Tree — Integration Guide

> A native macOS conversation app with tree-structured branching timelines for AI sessions.
> Built for Evan's Cortana setup. This guide covers what Friday and Jarvis need to adapt it for their own AI assistants and infrastructure.

---

## What This App Does

World Tree is a macOS conversation browser that gives AI sessions a branching, tree-like structure. Think of it like git branches for conversations — you can fork any message into a new direction without losing the original thread.

Core capabilities:
- Tree-structured conversations with forkable branches
- Connects to multiple AI backends (Claude CLI, Anthropic API, Ollama, or any LLM provider)
- Shares a SQLite database with your AI's CLI tooling
- Monitors a background AI daemon process (optional)
- Built-in terminal emulator per branch (tmux-backed)
- Project intelligence scanner
- Context pressure tracking (so you know when a session is getting too long)

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — generates the Xcode project from `project.yml`
- [Swift Package Manager](https://www.swift.org/package-manager/) — handles dependencies (GRDB, SwiftTerm)

```bash
# Install XcodeGen if you don't have it
brew install xcodegen
```

---

## Quick Build

```bash
git clone <this-repo>
cd world-tree
xcodegen                         # Generates WorldTree.xcodeproj
open WorldTree.xcodeproj         # Open in Xcode, then Cmd+R to build
```

Or from the command line:
```bash
xcodebuild -scheme WorldTree -configuration Debug build
```

The app will be at `build/Build/Products/Debug/World Tree.app`.

---

## What You MUST Change

These are hard-coded to Evan's infrastructure. You'll break things if you don't update them.

### 1. Database Path (`Sources/Shared/Constants.swift`)

The app expects a SQLite database at a specific path. Change this to wherever your AI's database lives.

```swift
enum CortanaConstants {  // ← rename this to match your AI if you want

    // PRIMARY: Where your AI stores conversation data
    static let dropboxDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // CHANGE THIS to your actual database path
        return "\(home)/Library/CloudStorage/Dropbox/claude-memory/conversations.db"
    }()

    // FALLBACK: Used if primary path isn't accessible
    static let fallbackDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // CHANGE THIS to your local fallback
        return "\(home)/.cortana/cortana.db"
    }()
```

**Your database doesn't need to match Evan's schema exactly.** See the "Database Schema" section below for what tables the app creates vs. what it expects to already exist.

### 2. AI Identity (`Sources/Core/Providers/CortanaIdentity.swift`)

This file contains the full personality and system prompt injected into your AI assistant. **Replace everything inside `fullIdentity()` and `cliSystemPrompt()` with your AI's actual persona.**

The structure to keep:
```swift
static func fullIdentity(project: String?, workingDirectory: String?) -> String {
    var identity = """
        [YOUR AI'S SYSTEM PROMPT HERE]
        """
    // These dynamic injections are useful to keep:
    if let project { identity += "\nActive project: \(project)." }
    if let cwd = workingDirectory { identity += "\nWorking directory: \(cwd)" }
    identity += "\nPlatform: macOS (darwin). Home: \(home)"
    return identity
}
```

The `fullIdentity` function is used by the **Anthropic API provider** (direct API calls).
The `cliSystemPrompt` function is used by the **Claude Code CLI provider** (CLI-based inference).

If your AI isn't Claude-based, see the Provider section below.

### 3. Daemon Socket (`Sources/Shared/Constants.swift`)

The app can optionally monitor a background AI daemon. If your AI has a daemon, update these paths:

```swift
static let daemonSocketPath = "\(home)/.cortana/daemon/cortana.sock"
static let daemonHealthPath = "\(home)/.cortana/daemon/.health"
static let daemonLogsDir   = "\(home)/.cortana/logs"
```

If you don't have a daemon, the daemon features just degrade gracefully — the status shows as "offline" and the daemon-related views will be empty. You don't need to remove the code, just set the paths to non-existent locations.

### 4. Claude CLI Path (`Sources/Shared/Constants.swift`)

```swift
static let claudeCliPath = "\(home)/.local/bin/claude"
```

If you're using the Claude Code CLI provider (Anthropic), this needs to point to where your `claude` binary lives. If you're not using Claude Code, you can ignore this or point it elsewhere — the CLI provider just won't work unless the binary exists.

### 5. Bundle Identifier (`project.yml`)

Change the bundle ID to yours before distributing or signing:
```yaml
PRODUCT_BUNDLE_IDENTIFIER: com.forgeandcode.world-tree  # ← change to your domain
```

---

## Database Schema

The app uses two layers:

**Layer 1 — Tables it creates itself** (via `Sources/Core/Database/MigrationManager.swift`)

These are created automatically on first launch. You don't need to set these up:

| Table | Purpose |
|-------|---------|
| `canvas_trees` | Conversation tree containers |
| `canvas_branches` | Branch fork points |
| `canvas_branch_tags` | Branch organization |
| `canvas_api_state` | Serialized API state per session |
| `canvas_token_usage` | Per-turn token tracking |
| `canvas_jobs` | Background job queue |
| `project_cache` | Project scanner cache |
| `canvas_cli_sessions` | CLI session mapping |
| `canvas_events` | Event log |
| `canvas_context_checkpoints` | Context rotation state |
| `canvas_tmux_sessions` | Terminal session names |
| `canvas_screenshots` | Screenshot capture log |

**Layer 2 — Tables it reads from (shared with your AI's CLI)** (`Sources/Core/Database/TreeStore.swift`, `MessageStore.swift`)

The app was designed to overlay on top of Evan's existing cortana CLI database. If your AI has a different schema, you have two options:

**Option A — Standalone mode**: Use a fresh database with only the `canvas_*` tables. Remove the `sessions`-table reads from `TreeStore.swift` and `MessageStore.swift`, and drive all conversation data through the canvas tables directly. This is the cleanest path for a fresh setup.

**Option B — Overlay mode**: Wire `canvas_branches` to reference your AI's existing session/conversation table. The foreign key in `canvas_branches` links to `sessions(id)` — rename this to match your existing conversation table.

---

## Swapping the AI Provider

The provider system is already abstracted. There's a protocol: `Sources/Core/Providers/LLMProvider.swift`.

Available implementations:
- `AnthropicAPIProvider.swift` — Direct Anthropic API calls. Works out of the box if you have an Anthropic API key.
- `ClaudeCodeProvider.swift` — Streams from the `claude` CLI binary.
- `OllamaProvider.swift` — Local Ollama inference. Change the endpoint in the provider file.
- `RemoteCanvasProvider.swift` — Forwards messages to another running World Tree instance over HTTP.

**To add your own provider**, implement `LLMProvider`:
```swift
protocol LLMProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func send(messages: [Message], systemPrompt: String?) async throws -> AsyncThrowingStream<String, Error>
    func cancel()
}
```

Register it in `Sources/Core/Providers/ProviderManager.swift`.

**Anthropic API Key**: If using `AnthropicAPIProvider`, the key is read from `ANTHROPIC_API_KEY` environment variable or from `AnthropicClient.swift`. Set it in your shell environment before launching, or update `AnthropicClient.swift` to read from your preferred keychain/secrets location.

---

## Naming & Branding

All user-visible "World Tree" references are in:
- `project.yml` — `PRODUCT_NAME`
- `Sources/App/CortanaCanvasApp.swift` — app struct, error alerts
- `Sources/Features/Dashboard/DashboardView.swift` — hero title
- `Sources/Core/Providers/CortanaIdentity.swift` — system prompt references

Internal class names (`CortanaConstants`, `CortanaIdentity`, `canvasLog`) are still named after Evan's setup. They work fine as-is. If you want full consistency, do a project-wide find/replace:
- `CortanaConstants` → `AppConstants` (or your equivalent)
- `CortanaIdentity` → `AssistantIdentity`
- `canvasLog` → `appLog`

---

## File Structure Reference

```
Sources/
├── App/                    ← Entry point. Start here.
│   ├── WorldTreeApp.swift  ← @main struct, startup hooks
│   ├── ContentView.swift   ← Root NavigationSplitView
│   └── AppState.swift      ← Global state container
│
├── Core/                   ← All business logic. No UI here.
│   ├── Database/           ← SQLite via GRDB. Schema migrations.
│   ├── Claude/             ← Anthropic API client and types
│   ├── Providers/          ← LLM provider abstraction + implementations
│   │   └── CortanaIdentity.swift  ← ⚠️ REPLACE with your AI's identity
│   ├── Daemon/             ← Background daemon monitoring (optional)
│   ├── Context/            ← Token counting, session rotation
│   ├── ProjectIntelligence/ ← Filesystem project scanner
│   └── Models/             ← Core data models
│
├── Features/               ← UI screens. Each folder = one screen.
│   ├── Dashboard/          ← Home screen with tree list
│   ├── Sidebar/            ← Left nav: tree + branch explorer
│   ├── Canvas/             ← Conversation display
│   ├── Settings/           ← User preferences
│   └── ...
│
└── Shared/
    ├── Constants.swift     ← ⚠️ ALL paths and defaults live here
    └── Components/         ← Reusable UI components
```

---

## Things That Are Specific to Evan's Setup (Don't Need to Work)

These features reference Evan's specific infrastructure. They'll fail silently or show as offline if the backing service doesn't exist — they won't crash the app.

| Feature | What It Needs | What Happens Without It |
|---------|--------------|------------------------|
| Dropbox sync | Dropbox at the configured path | Falls back to local DB |
| Cortana Daemon | `~/.cortana/daemon/cortana.sock` | Shows "daemon offline", no live session monitoring |
| Claude Code CLI | `~/.local/bin/claude` binary | "claude-code" provider fails; use "api" provider instead |
| Ark Gateway | `Sources/Core/Gateway/GatewayClient.swift` | Gateway features unavailable |
| Remote Canvas | Another World Tree instance running in server mode | Remote provider unavailable |
| Canvas Server | HTTP server mode (opt-in via Settings) | Disabled by default, no impact |

---

## Database Connection Tips

GRDB is configured with WAL mode and a 5-second busy timeout. If you're connecting to a database that another process also writes to (e.g., your AI's CLI), this is safe — WAL allows concurrent readers and one writer.

If you see database-locked errors, increase `PRAGMA busy_timeout` in `DatabaseManager.swift`:
```swift
try db.execute(sql: "PRAGMA busy_timeout = 10000")  // 10 seconds
```

---

## Questions / Issues

Open an issue on the repo or reach out to Evan. The app is a working daily driver, not a demo — it's reasonably solid but the integration points above genuinely require your attention.

💠
