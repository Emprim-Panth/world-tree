# World Tree — Conversation Tree Interface

> Cortana's home. Tree-structured branching conversations with daemon integration.

## Stack
- **Platform**: macOS 14+ (SwiftUI)
- **Database**: SQLite via GRDB.swift (shared `conversations.db`, WAL mode)
- **IPC**: Unix domain socket to cortana-daemon
- **Build**: XcodeGen (`project.yml`)

## Build & Run
```bash
xcodegen                            # Generate .xcodeproj
xcodebuild -scheme WorldTree        # Build
open WorldTree.xcodeproj            # Open in Xcode
```

## Architecture

```
Sources/
├── App/          # @main entry, AppState
├── Core/
│   ├── Database/ # DatabaseManager, TreeStore, MessageStore, Migrations
│   ├── Daemon/   # Unix socket client, log tailer
│   ├── Claude/   # ClaudeBridge — send/fork dispatch
│   └── Models/   # ConversationTree, Branch, Message
├── Features/
│   ├── Sidebar/       # Tree browser with recursive branch nodes
│   ├── Canvas/        # Conversation view, message rows, fork menu
│   ├── CommandCenter/ # Compass project cards, dispatch, activity overview
│   ├── Tickets/       # Ticket list, detail, inline status toggle
│   ├── Terminal/      # Project + branch terminals (NSViewRepresentable)
│   ├── Document/      # Single document view with integrated terminal
│   └── Settings/      # Configuration
└── Shared/       # Components, extensions, constants
```

## Key Invariants

1. **Zero changes** to existing `sessions`, `messages` tables — canvas_* tables overlay
2. **WAL mode** with `busy_timeout = 5000` — matches cortana-core exactly
3. **Sessions created by Canvas** must match cortana-core INSERT pattern
4. **Daemon communication** via Unix socket at `~/.cortana/daemon/cortana.sock`
5. **Branch context** injected as system message when forking

## Database

Shared: `~/.cortana/claude-memory/conversations.db`
Canvas tables: `canvas_trees`, `canvas_branches`, `canvas_tickets`, `canvas_dispatches`, `canvas_jobs`
Compass (read-write): `~/.cortana/compass.db` — project state read/written by World Tree and cortana-core MCP

## Tickets

Tickets live as `TASK-*.md` files in `.claude/epic/tasks/`. Compass scans them into `canvas_tickets` for the Command Center. Use `compass_tickets WorldTree` to see open work.

## Anti-Duplication Rule

When refactoring replaces a file with a new implementation, **delete the old file in the same commit**. Do not leave superseded files as "for reference". Stranded dead code accumulates silently — two known culprits already removed (ContextBuilder.swift superseded by SendContextBuilder; VMExecutor.swift — speculative stub never completed).
