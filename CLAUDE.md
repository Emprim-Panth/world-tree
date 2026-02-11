# Cortana Canvas — Conversation Tree Interface

> Cortana's home. Tree-structured branching conversations with daemon integration.

## Stack
- **Platform**: macOS 14+ (SwiftUI)
- **Database**: SQLite via GRDB.swift (shared `conversations.db`, WAL mode)
- **IPC**: Unix domain socket to cortana-daemon
- **Build**: XcodeGen (`project.yml`)

## Build & Run
```bash
xcodegen                            # Generate .xcodeproj
xcodebuild -scheme CortanaCanvas    # Build
open CortanaCanvas.xcodeproj        # Open in Xcode
```

## Architecture

```
Sources/
├── App/          # @main entry, AppState
├── Core/
│   ├── Database/ # DatabaseManager, TreeStore, MessageStore, Migrations
│   ├── Daemon/   # Unix socket client, log tailer
│   ├── Claude/   # Context builder for branch forks
│   └── Models/   # ConversationTree, Branch, Message
├── Features/
│   ├── Sidebar/  # Tree browser with recursive branch nodes
│   ├── Canvas/   # Conversation view, message rows, fork menu
│   ├── Implementation/ # Live daemon session view
│   ├── Dashboard/ # Overview + quick actions
│   └── Settings/  # Configuration
└── Shared/       # Components, extensions, constants
```

## Key Invariants

1. **Zero changes** to existing `sessions`, `messages` tables — canvas_* tables overlay
2. **WAL mode** with `busy_timeout = 5000` — matches cortana-core exactly
3. **Sessions created by Canvas** must match cortana-core INSERT pattern
4. **Daemon communication** via Unix socket at `~/.cortana/daemon/cortana.sock`
5. **Branch context** injected as system message when forking

## Database

Shared: `~/Library/CloudStorage/Dropbox/claude-memory/conversations.db`
Canvas adds: `canvas_trees`, `canvas_branches` tables (prefixed, isolated)
