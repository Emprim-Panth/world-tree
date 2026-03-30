# World Tree — Command Center & Intelligence Dashboard

> Cortana's home. Project management, agent orchestration, and local intelligence.

## Stack
- **Platform**: macOS 14+ (SwiftUI)
- **Database**: SQLite via GRDB.swift (shared `conversations.db`, WAL mode)
- **Intelligence**: Ollama fleet (qwen2.5:72b, qwen2.5-coder:32b, nomic-embed-text)
- **Build**: XcodeGen (`project.yml`)

## Build & Run
```bash
xcodegen                            # Generate .xcodeproj
xcodebuild -scheme WorldTree        # Build
open WorldTree.xcodeproj            # Open in Xcode
make install                        # Build + install to /Applications
```

## Architecture

```
Sources/
├── App/              # @main entry, AppState, ContentView
├── Core/
│   ├── Database/     # DatabaseManager, MigrationManager, CompassStore,
│   │                 # HeartbeatStore, TicketStore, SessionStateStore
│   ├── BrainHost/    # CentralBrainStore, BrainFileStore
│   ├── ContextServer/# HTTP server (port 4863) — project context + agent routes
│   ├── Intelligence/ # BrainIndexer (FTS5 + semantic), QualityRouter (Ollama)
│   ├── Gateway/      # GatewayClient — handoffs, agent events
│   ├── Models/       # Dispatch model
│   └── Notifications/# macOS notifications
├── Features/
│   ├── CommandCenter/ # Compass project cards, dispatch activity, intelligence dashboard
│   ├── Tickets/       # Ticket list, detail, inline status toggle
│   ├── Brain/         # Brain editor, Central Brain viewer
│   ├── AgentLab/      # Agent proof viewer, cast replay, live screenshots
│   └── Settings/      # Configuration
└── Shared/           # Palette (design tokens), constants, utilities, extensions
```

## Key Invariants

1. **Never touch** cortana-core tables (`sessions`, `messages`, `summaries`, `agent_attention_events`)
2. **WAL mode** with `busy_timeout = 5000` — matches cortana-core exactly
3. **Never use `try?`** on database or network calls — use `do/catch` + `wtLog`
4. **Use `Palette.*`** for all view colors — no bare `.red`, `.blue`, `Color(NSColor.*)` etc.
5. **Delete superseded files** in the same commit — no dead code
6. **Use Developer cert** for signing (Team: F75F8Z9ZPZ) — never ad-hoc

## Database

Shared: `~/.cortana/claude-memory/conversations.db`
Canvas tables: `canvas_tickets`, `canvas_dispatches`
Agent tables: `agent_sessions`, `agent_screenshots`, `inference_log`
Compass (read-write): `~/.cortana/compass.db`
Brain index: `~/.cortana/brain-index.db` (FTS5 + embeddings)

## ContextServer Routes (port 4863)

- `GET /context/{project}` — project context for Claude sessions
- `GET /brain/search?q=...` — semantic brain search
- `GET /intelligence/status` — model fleet + routing stats
- `GET/POST /agent/*` — agent session tracking + proof delivery
- `POST /session/summary` — session summary from Claude Code hooks

## Tickets

Tickets live as `TASK-*.md` files in `.claude/epic/tasks/`. Compass scans them into `canvas_tickets` for the Command Center. Use `compass_tickets WorldTree` to see open work.
