# CortanaCanvas Vision: Implementation Plan

> **Target**: Transform Canvas into a living document interface with visible terminals, branching conversations, voice streaming, and unified cross-device memory.
>
> **Status**: Architecture 70% complete. Infrastructure exists but disconnected. Estimated 7-9 days focused work.

---

## Executive Summary

**The Vision**: CortanaCanvas becomes the definitive development environment:
- **Living Document Interface** — Google Docs style collaboration, no chat bubbles
- **Visual Branching** — Conversations diverge to the right, parallel exploration
- **Visible Terminals** — TMUX-style integrated terminals, no background processes
- **Voice Streaming** — Full conversation streams with voice input/output
- **Compaction Control** — Never fully compact, maintain full context history
- **Multi-Project Management** — Branches become projects/versions, work on many ideas at once

**The Reality**: We have 70% of the infrastructure already built:
- ✅ Context rotation system (excellent)
- ✅ Branch forking and summarization
- ✅ Tool execution (sandboxed bash, file ops)
- ✅ Gateway coordination hub (operational)
- ✅ Database persistence (SQLite + GRDB)
- ❌ Canvas ↔ Gateway integration (missing)
- ❌ Living document UI (currently chat bubbles)
- ❌ Terminal visibility (terminals run hidden)
- ❌ Voice streaming (not implemented)
- ❌ Cross-device sync (planned but not working)

**The Gap**: 8 hours of focused integration work closes 70% of the gaps. The remaining 30% is new features (voice, living document UI, enhanced compaction control).

---

## Phase 1: Quick Wins — Integration (1-2 Days)

### Goal
Connect the existing systems so they actually talk to each other.

### 1.1 Gateway Memory API Implementation

**File**: `~/Development/ark-gateway/src/main.rs`

**Task**: Implement the documented but missing memory endpoints.

```rust
// Add these endpoints (lines ~500-600)

// POST /memory/log
async fn log_memory(
    State(state): State<AppState>,
    Json(payload): Json<MemoryLogRequest>,
) -> Result<Json<MemoryLogResponse>, StatusCode> {
    // Insert into knowledge base
    // Broadcast event to connected clients
}

// GET /memory/search
async fn search_memory(
    State(state): State<AppState>,
    Query(params): Query<MemorySearchParams>,
) -> Result<Json<Vec<MemoryEntry>>, StatusCode> {
    // Query knowledge base
    // Return ranked results
}

// GET /memory/recent
async fn recent_memory(
    State(state): State<AppState>,
    Query(params): Query<RecentParams>,
) -> Result<Json<Vec<MemoryEntry>>, StatusCode> {
    // Get N most recent entries
}
```

**Database Schema** (add to gateway's cortana.db):
```sql
CREATE TABLE IF NOT EXISTS knowledge_base (
    id INTEGER PRIMARY KEY,
    category TEXT NOT NULL,
    content TEXT NOT NULL,
    metadata TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    project TEXT,
    tags TEXT
);

CREATE INDEX idx_knowledge_category ON knowledge_base(category);
CREATE INDEX idx_knowledge_project ON knowledge_base(project);
CREATE VIRTUAL TABLE knowledge_fts USING fts5(content, content=knowledge_base);
```

**Effort**: 2 hours

---

### 1.2 Canvas → Gateway Connection

**File**: `~/Development/CortanaCanvas/Sources/Core/Gateway/GatewayClient.swift` (new)

**Task**: Create HTTP client that connects Canvas to Gateway.

```swift
import Foundation

actor GatewayClient {
    private let baseURL = URL(string: "http://localhost:4862")!
    private let session = URLSession.shared

    // Memory Operations
    func logMemory(category: String, content: String, project: String?) async throws {
        let endpoint = baseURL.appendingPathComponent("/memory/log")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = MemoryLogRequest(
            category: category,
            content: content,
            project: project
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GatewayError.requestFailed
        }
    }

    func searchMemory(query: String, project: String? = nil) async throws -> [MemoryEntry] {
        var components = URLComponents(url: baseURL.appendingPathComponent("/memory/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            project.map { URLQueryItem(name: "project", value: $0) }
        ].compactMap { $0 }

        let (data, _) = try await session.data(from: components.url!)
        return try JSONDecoder().decode([MemoryEntry].self, from: data)
    }

    // Handoff Operations
    func checkHandoffs() async throws -> [Handoff] {
        let endpoint = baseURL.appendingPathComponent("/handoffs/pending")
        let (data, _) = try await session.data(from: endpoint)
        return try JSONDecoder().decode([Handoff].self, from: data)
    }

    func updateHandoff(id: String, status: String) async throws {
        let endpoint = baseURL.appendingPathComponent("/handoffs/\(id)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["status": status]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GatewayError.requestFailed
        }
    }

    // SSE Connection for Events
    func subscribeToEvents() -> AsyncStream<GatewayEvent> {
        AsyncStream { continuation in
            Task {
                let url = baseURL.appendingPathComponent("/events")
                let (bytes, _) = try await session.bytes(from: url)

                for try await line in bytes.lines {
                    if line.hasPrefix("data: ") {
                        let json = String(line.dropFirst(6))
                        if let data = json.data(using: .utf8),
                           let event = try? JSONDecoder().decode(GatewayEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    }
                }
            }
        }
    }
}

struct MemoryLogRequest: Codable {
    let category: String
    let content: String
    let project: String?
}

struct MemoryEntry: Codable, Identifiable {
    let id: Int
    let category: String
    let content: String
    let createdAt: Date
    let project: String?
    let tags: [String]?
}

struct Handoff: Codable, Identifiable {
    let id: String
    let project: String
    let status: String
    let done: String
    let leftOff: String
    let nextSteps: String
    let createdAt: Date
}

struct GatewayEvent: Codable {
    let type: String
    let data: [String: String]
}

enum GatewayError: Error {
    case requestFailed
    case invalidResponse
}
```

**Integration Points**:
- Call `gatewayClient.logMemory()` when session ends
- Check `gatewayClient.checkHandoffs()` on app launch
- Subscribe to `gatewayClient.subscribeToEvents()` for real-time updates

**Effort**: 3 hours

---

### 1.3 Telegram Bot → Gateway Integration

**File**: `~/.claude/telegram/bot.py`

**Task**: Make the bot bidirectional — poll gateway events and send to Telegram.

```python
# Add SSE client for gateway events
import sseclient
import requests
import threading

def poll_gateway_events():
    """Subscribe to gateway SSE events and forward to Telegram"""
    url = "http://localhost:4862/events"

    while True:
        try:
            response = requests.get(url, stream=True)
            client = sseclient.SSEClient(response)

            for event in client.events():
                data = json.loads(event.data)

                # Forward relevant events to Telegram
                if data['type'] in ['handoff_created', 'task_assigned', 'alert']:
                    send_telegram_message(
                        chat_id=EVAN_CHAT_ID,
                        message=format_event_message(data)
                    )
        except Exception as e:
            logger.error(f"Gateway connection lost: {e}")
            time.sleep(5)  # Reconnect after 5 seconds

# Start polling in background thread
threading.Thread(target=poll_gateway_events, daemon=True).start()
```

**Effort**: 1 hour

---

### 1.4 Session Startup Hooks

**File**: `~/.claude/hooks/SessionStart.sh`

**Task**: Check for pending handoffs on session start.

```bash
#!/bin/bash
# Session startup hook — check for pending work

# Query gateway for pending handoffs
HANDOFFS=$(curl -s http://localhost:4862/handoffs/pending)

if [ -n "$HANDOFFS" ] && [ "$HANDOFFS" != "[]" ]; then
    echo "📋 Pending Handoffs Found:"
    echo "$HANDOFFS" | jq -r '.[] | "  • [\(.project)] \(.leftOff)"'
    echo ""
fi

# Check for high-priority alerts
ALERTS=$(curl -s "http://localhost:4862/memory/search?q=priority:high&limit=5")

if [ -n "$ALERTS" ] && [ "$ALERTS" != "[]" ]; then
    echo "⚠️  Recent Alerts:"
    echo "$ALERTS" | jq -r '.[] | "  • \(.content)"'
    echo ""
fi
```

**Effort**: 1 hour

---

**Phase 1 Total**: 7 hours
**Result**: All systems connected, cross-device sync working, Telegram fully bidirectional

---

## Phase 2: Memory Unification (1 Day)

### Goal
Merge separate databases into unified knowledge graph accessible from all devices.

### 2.1 Database Migration

**Task**: Merge Canvas conversations.db into gateway's cortana.db.

**Current State**:
- Gateway DB: `~/.cortana/cortana.db` (inbox, handoffs, project_state, dispatch_queue, task_chains)
- Canvas DB: `~/Library/CloudStorage/Dropbox/claude-memory/conversations.db` (sessions, messages, canvas_trees, canvas_branches)

**Target State**: Single database at `~/.cortana/cortana.db` with all tables.

**Migration Script**:
```bash
#!/bin/bash
# Merge Canvas DB into Gateway DB

SOURCE="$HOME/Library/CloudStorage/Dropbox/claude-memory/conversations.db"
TARGET="$HOME/.cortana/cortana.db"

# Backup first
cp "$TARGET" "$TARGET.backup"

# Attach Canvas DB and copy tables
sqlite3 "$TARGET" <<EOF
ATTACH DATABASE '$SOURCE' AS canvas;

-- Copy core tables
INSERT INTO sessions SELECT * FROM canvas.sessions;
INSERT INTO messages SELECT * FROM canvas.messages;

-- Copy Canvas-specific tables
CREATE TABLE IF NOT EXISTS canvas_trees AS SELECT * FROM canvas.canvas_trees;
CREATE TABLE IF NOT EXISTS canvas_branches AS SELECT * FROM canvas.canvas_branches;
CREATE TABLE IF NOT EXISTS canvas_context_checkpoints AS SELECT * FROM canvas.canvas_context_checkpoints;

DETACH DATABASE canvas;
EOF

echo "✅ Database merged successfully"
echo "Location: $TARGET"
```

**Update Canvas Code**:
```swift
// In TreeStore.swift, update database path
private static var databasePath: String {
    // OLD: ~/Library/CloudStorage/Dropbox/claude-memory/conversations.db
    // NEW: ~/.cortana/cortana.db
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cortana")
        .appendingPathComponent("cortana.db")
        .path
}
```

**Effort**: 4 hours

---

### 2.2 Knowledge Base Integration

**Task**: Replace Canvas's isolated knowledge with gateway queries.

**Before** (local only):
```swift
// Canvas queries its own DB
func searchKnowledge(query: String) -> [KnowledgeEntry] {
    // Local SQL query
}
```

**After** (gateway-powered):
```swift
// Canvas queries unified KB via gateway
func searchKnowledge(query: String) async throws -> [MemoryEntry] {
    return try await gatewayClient.searchMemory(query: query)
}
```

**Effort**: 2 hours

---

**Phase 2 Total**: 6 hours
**Result**: Single source of truth for all memory, accessible from terminal/Canvas/Telegram

---

## Phase 3: Terminal Integration (2 Days)

### Goal
Replace hidden background terminals with visible, integrated TMUX-style interface.

### 3.1 PTY Session Management

**Current State**: `ToolExecutor.swift` runs bash commands in background NSTask.

**Target State**: PTY sessions managed by gateway, displayed in Canvas.

**Gateway Enhancement** (`~/Development/ark-gateway/src/terminal.rs` — new):

```rust
use portable_pty::{native_pty_system, PtySize, CommandBuilder};
use std::io::{Read, Write};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

pub struct TerminalManager {
    sessions: Arc<Mutex<HashMap<String, TerminalSession>>>,
}

pub struct TerminalSession {
    pty: Box<dyn portable_pty::MasterPty>,
    process: Box<dyn portable_pty::Child>,
    output_buffer: String,
}

impl TerminalManager {
    pub async fn create_session(&self, id: String, cwd: String) -> Result<()> {
        let pty_system = native_pty_system();

        let pair = pty_system.openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let mut cmd = CommandBuilder::new("bash");
        cmd.cwd(cwd);

        let child = pair.slave.spawn_command(cmd)?;

        let session = TerminalSession {
            pty: pair.master,
            process: child,
            output_buffer: String::new(),
        };

        self.sessions.lock().await.insert(id, session);
        Ok(())
    }

    pub async fn send_command(&self, id: &str, command: &str) -> Result<()> {
        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.get_mut(id) {
            write!(session.pty, "{}\n", command)?;
        }
        Ok(())
    }

    pub async fn read_output(&self, id: &str) -> Result<String> {
        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.get_mut(id) {
            let mut buf = [0u8; 8192];
            if let Ok(n) = session.pty.try_read(&mut buf) {
                let output = String::from_utf8_lossy(&buf[..n]).to_string();
                session.output_buffer.push_str(&output);
                return Ok(output);
            }
        }
        Ok(String::new())
    }
}
```

**Gateway Endpoints** (add to main.rs):
```rust
// POST /terminal/create
// POST /terminal/{id}/command
// GET /terminal/{id}/output (SSE stream)
// DELETE /terminal/{id}
```

**Effort**: 6 hours

---

### 3.2 Canvas Terminal View

**File**: `~/Development/CortanaCanvas/Sources/Features/Terminal/TerminalView.swift` (new)

**Task**: Create visible terminal display component.

```swift
import SwiftUI

struct TerminalView: View {
    @StateObject private var viewModel: TerminalViewModel
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.lines) { line in
                            TerminalLine(line: line)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .black))
                .onChange(of: viewModel.lines.count) { _ in
                    proxy.scrollTo(viewModel.lines.last?.id, anchor: .bottom)
                }
            }

            // Input prompt
            HStack(spacing: 4) {
                Text(viewModel.prompt)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.green)

                TextField("", text: $inputText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .onSubmit {
                        viewModel.sendCommand(inputText)
                        inputText = ""
                    }
            }
            .padding(8)
            .background(Color(nsColor: .black))
        }
    }
}

struct TerminalLine: View {
    let line: TerminalOutputLine

    var body: some View {
        Text(line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(line.color)
            .textSelection(.enabled)
    }
}

@MainActor
class TerminalViewModel: ObservableObject {
    @Published var lines: [TerminalOutputLine] = []
    @Published var prompt = "$ "

    private let gatewayClient: GatewayClient
    private let sessionId: String

    init(sessionId: String, gatewayClient: GatewayClient) {
        self.sessionId = sessionId
        self.gatewayClient = gatewayClient

        // Subscribe to output stream
        Task {
            for await output in gatewayClient.subscribeToTerminal(sessionId: sessionId) {
                parseOutput(output)
            }
        }
    }

    func sendCommand(_ command: String) {
        // Echo command
        lines.append(TerminalOutputLine(
            text: prompt + command,
            color: .white
        ))

        // Send to gateway
        Task {
            try? await gatewayClient.sendTerminalCommand(
                sessionId: sessionId,
                command: command
            )
        }
    }

    private func parseOutput(_ output: String) {
        // Parse ANSI codes and create formatted lines
        let parsed = ANSIParser.parse(output)
        lines.append(contentsOf: parsed)
    }
}

struct TerminalOutputLine: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}
```

**Effort**: 6 hours

---

**Phase 3 Total**: 12 hours
**Result**: Fully visible terminals integrated into Canvas, no hidden processes

---

## Phase 4: Living Document UI (3-4 Days)

### Goal
Transform chat bubbles into collaborative document interface (Google Docs style).

### 4.1 Document Model

**Concept**: Messages are no longer discrete bubbles. The entire conversation is a single continuous document with inline editing capabilities.

**File**: `~/Development/CortanaCanvas/Sources/Features/Document/DocumentModel.swift` (new)

```swift
import Foundation

struct ConversationDocument {
    var sections: [DocumentSection]
    var cursors: [Cursor]  // Multi-cursor support
}

struct DocumentSection: Identifiable {
    let id: UUID
    var content: AttributedString
    var author: Author
    var timestamp: Date
    var branchPoint: Bool  // Can this section become a branch?
    var metadata: SectionMetadata
}

enum Author {
    case user(name: String)
    case assistant
    case system
}

struct SectionMetadata {
    var toolCalls: [ToolCall]?
    var codeBlocks: [CodeBlock]?
    var attachments: [Attachment]?
}

struct Cursor: Identifiable {
    let id: UUID
    var position: Int  // Character offset in document
    var owner: Author
}

struct CodeBlock: Identifiable {
    let id: UUID
    var language: String
    var code: String
    var filePath: String?
}
```

**Effort**: 4 hours

---

### 4.2 Document Editor View

**File**: `~/Development/CortanaCanvas/Sources/Features/Document/DocumentEditorView.swift` (new)

**Task**: Replace chat bubble UI with continuous document editor.

```swift
import SwiftUI

struct DocumentEditorView: View {
    @StateObject private var viewModel: DocumentEditorViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.document.sections) { section in
                        DocumentSectionView(
                            section: section,
                            isEditable: section.author == .user,
                            onEdit: { newContent in
                                viewModel.updateSection(section.id, content: newContent)
                            },
                            onBranch: {
                                viewModel.createBranch(from: section.id)
                            }
                        )
                        .id(section.id)
                        .contextMenu {
                            Button("Branch from here") {
                                viewModel.createBranch(from: section.id)
                            }
                            Button("Edit") {
                                viewModel.startEditing(section.id)
                            }
                            Button("Copy") {
                                NSPasteboard.general.setString(section.content.string, forType: .string)
                            }
                        }
                    }

                    // User input area (always at bottom)
                    UserInputArea(
                        text: $viewModel.currentInput,
                        onSubmit: { viewModel.submitInput() }
                    )
                    .focused($isFocused)
                }
                .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { isFocused = true }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: { viewModel.showBranchView() }) {
                    Label("Branches", systemImage: "arrow.triangle.branch")
                }
                Button(action: { viewModel.showCompactionControl() }) {
                    Label("Context", systemImage: "gauge")
                }
            }
        }
    }
}

struct DocumentSectionView: View {
    let section: DocumentSection
    let isEditable: Bool
    let onEdit: (AttributedString) -> Void
    let onBranch: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Author indicator (subtle, left margin)
            AuthorIndicator(author: section.author)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                // Content (editable if user-authored)
                if isEditable {
                    EditableTextView(
                        content: section.content,
                        onChange: onEdit
                    )
                } else {
                    Text(section.content)
                        .textSelection(.enabled)
                }

                // Metadata (code blocks, tool calls, etc.)
                if let toolCalls = section.metadata.toolCalls {
                    ForEach(toolCalls) { call in
                        ToolCallView(call: call)
                    }
                }

                if let codeBlocks = section.metadata.codeBlocks {
                    ForEach(codeBlocks) { block in
                        CodeBlockView(block: block)
                    }
                }
            }
            .padding(.vertical, 8)

            Spacer()

            // Branch button (appears on hover)
            if isHovering && section.branchPoint {
                Button(action: onBranch) {
                    Image(systemName: "arrow.turn.up.right")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct AuthorIndicator: View {
    let author: Author

    var body: some View {
        Rectangle()
            .fill(color)
            .cornerRadius(2)
    }

    private var color: Color {
        switch author {
        case .user: return .blue
        case .assistant: return .purple
        case .system: return .gray
        }
    }
}
```

**Effort**: 12 hours

---

### 4.3 Inline Editing

**Task**: Allow editing any part of the document, creating branches from edits.

**Feature**: Click anywhere in the conversation to edit. When you change your previous message, it creates a branch automatically.

```swift
struct EditableTextView: NSViewRepresentable {
    var content: AttributedString
    var onChange: (AttributedString) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = true
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(NSAttributedString(content))
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.attributedString() != NSAttributedString(content) {
            nsView.textStorage?.setAttributedString(NSAttributedString(content))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (AttributedString) -> Void

        init(onChange: @escaping (AttributedString) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let attributedString = AttributedString(textView.attributedString())
            onChange(attributedString)
        }
    }
}
```

**Effort**: 8 hours

---

**Phase 4 Total**: 24 hours
**Result**: Living document interface with inline editing and natural branching

---

## Phase 5: Visual Branching (2 Days)

### Goal
Conversations diverge visually to the right when branching, creating parallel exploration paths.

### 5.1 Branch Layout System

**Concept**: When you create a branch, it appears as a column to the right of the parent conversation.

**File**: `~/Development/CortanaCanvas/Sources/Features/Document/BranchLayoutView.swift` (new)

```swift
import SwiftUI

struct BranchLayoutView: View {
    @StateObject private var viewModel: BranchLayoutViewModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(viewModel.visibleBranches) { branch in
                        BranchColumn(
                            branch: branch,
                            width: 600,
                            onCreateBranch: { sectionId in
                                viewModel.createBranch(from: sectionId, in: branch.id)
                            }
                        )
                        .frame(width: 600)
                    }
                }
                .padding()
            }
        }
    }
}

struct BranchColumn: View {
    let branch: Branch
    let width: CGFloat
    let onCreateBranch: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Branch header
            BranchHeader(branch: branch)

            Divider()

            // Document view for this branch
            DocumentEditorView(
                viewModel: DocumentEditorViewModel(branchId: branch.id),
                onBranch: onCreateBranch
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 2)
    }
}

struct BranchHeader: View {
    let branch: Branch

    var body: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(branch.title)
                    .font(.headline)

                if let checkpoint = branch.checkpoint {
                    Text(checkpoint.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(action: {}) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

@MainActor
class BranchLayoutViewModel: ObservableObject {
    @Published var visibleBranches: [Branch] = []

    private let treeStore: TreeStore
    private let currentTreeId: String

    init(treeStore: TreeStore, treeId: String) {
        self.treeStore = treeStore
        self.currentTreeId = treeId
        loadBranches()
    }

    func loadBranches() {
        // Load all branches for current tree
        // Arrange in visual hierarchy (parent → child → grandchild)
    }

    func createBranch(from sectionId: UUID, in parentBranchId: UUID) {
        // 1. Create new branch in DB
        // 2. Copy conversation up to sectionId
        // 3. Add to visibleBranches
        // 4. Animate slide-in from right
    }
}
```

**Effort**: 12 hours

---

### 5.2 Branch Navigation

**Task**: Mini-map showing branch hierarchy, click to jump between branches.

```swift
struct BranchNavigatorView: View {
    @Binding var visibleBranches: [Branch]
    let onSelectBranch: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(visibleBranches) { branch in
                    BranchMiniCard(branch: branch)
                        .onTapGesture {
                            onSelectBranch(branch.id)
                        }
                }
            }
            .padding()
        }
        .frame(height: 80)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct BranchMiniCard: View {
    let branch: Branch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(branch.title)
                .font(.caption.bold())
                .lineLimit(1)

            Text("\(branch.messageCount) messages")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(width: 120)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .shadow(radius: 1)
    }
}
```

**Effort**: 4 hours

---

**Phase 5 Total**: 16 hours
**Result**: Visual branching with side-by-side exploration, intuitive navigation

---

## Phase 6: Voice Streaming (2-3 Days)

### Goal
Full conversation streams with voice input/output, "vibe coding" interface.

### 6.1 Voice Input

**Task**: Real-time voice transcription using OpenAI Whisper API.

**File**: `~/Development/CortanaCanvas/Sources/Features/Voice/VoiceInputService.swift` (new)

```swift
import AVFoundation
import Foundation

actor VoiceInputService {
    private let audioEngine = AVAudioEngine()
    private let whisperAPIKey: String

    func startListening() -> AsyncStream<String> {
        AsyncStream { continuation in
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, time in
                // Buffer audio until silence detected or 30 seconds
                // Then send to Whisper API for transcription
                Task {
                    if let transcription = await self.transcribe(buffer: buffer) {
                        continuation.yield(transcription)
                    }
                }
            }

            audioEngine.prepare()
            try? audioEngine.start()
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func transcribe(buffer: AVAudioPCMBuffer) async -> String? {
        // Convert buffer to audio file
        // POST to Whisper API
        // Return transcription text
    }
}
```

**Effort**: 6 hours

---

### 6.2 Voice Output

**Task**: Stream Claude responses to text-to-speech.

```swift
import AVFoundation

actor VoiceOutputService {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(text: String, voice: AVSpeechSynthesisVoice? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(identifier: AVSpeechSynthesisVoiceIdentifierAlex)
        utterance.rate = 0.5

        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
```

**Effort**: 2 hours

---

### 6.3 Voice UI

**Task**: Floating voice controls, visualizer, "push to talk" or "continuous mode".

```swift
struct VoiceControlView: View {
    @StateObject private var viewModel: VoiceControlViewModel
    @State private var isListening = false

    var body: some View {
        VStack(spacing: 16) {
            // Waveform visualizer
            WaveformView(amplitude: viewModel.audioLevel)
                .frame(height: 60)

            // Status
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)

            // Push-to-talk button
            Button(action: { toggleListening() }) {
                Image(systemName: isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 32))
                    .foregroundColor(isListening ? .red : .blue)
            }
            .buttonStyle(.plain)

            // Mode toggle
            Toggle("Continuous Mode", isOn: $viewModel.continuousMode)
                .toggleStyle(.switch)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 4)
    }

    private var statusText: String {
        if isListening {
            return "Listening..."
        } else if viewModel.isProcessing {
            return "Processing..."
        } else {
            return "Ready"
        }
    }

    private func toggleListening() {
        if isListening {
            viewModel.stopListening()
        } else {
            viewModel.startListening()
        }
        isListening.toggle()
    }
}

struct WaveformView: View {
    let amplitude: Double

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let midY = height / 2

                path.move(to: CGPoint(x: 0, y: midY))

                for x in stride(from: 0, to: width, by: 2) {
                    let normalizedX = x / width
                    let sine = sin(normalizedX * .pi * 4) * amplitude
                    let y = midY + sine * (height / 2)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.blue, lineWidth: 2)
        }
    }
}
```

**Effort**: 8 hours

---

**Phase 6 Total**: 16 hours
**Result**: Full voice conversation capability, "vibe coding" ready

---

## Phase 7: Enhanced Compaction Control (1-2 Days)

### Goal
Never fully compact context window. User controls what stays, what rotates.

### 7.1 Context Inspector

**Task**: Visual interface showing context usage, marking sections as "keep" or "rotate".

**File**: `~/Development/CortanaCanvas/Sources/Features/Context/ContextInspectorView.swift` (new)

```swift
import SwiftUI

struct ContextInspectorView: View {
    @StateObject private var viewModel: ContextInspectorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Context gauge
            ContextGaugeView(
                current: viewModel.currentTokens,
                max: viewModel.maxTokens,
                threshold: viewModel.rotationThreshold
            )
            .padding()

            Divider()

            // Section list
            List(viewModel.sections) { section in
                ContextSectionRow(
                    section: section,
                    onToggleKeep: { viewModel.toggleKeep(section.id) }
                )
            }
        }
    }
}

struct ContextGaugeView: View {
    let current: Int
    let max: Int
    let threshold: Int

    var body: some View {
        VStack(spacing: 8) {
            Gauge(value: Double(current), in: 0...Double(max)) {
                Text("Context Usage")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(gaugeColor)

            HStack {
                Text("\(current.formatted()) / \(max.formatted()) tokens")
                    .font(.caption)

                Spacer()

                Text("Rotation at \(threshold.formatted())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var gaugeColor: Color {
        let percentage = Double(current) / Double(max)
        if percentage > 0.9 {
            return .red
        } else if percentage > 0.75 {
            return .orange
        } else {
            return .green
        }
    }
}

struct ContextSectionRow: View {
    let section: ContextSection
    let onToggleKeep: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.subheadline)

                Text("\(section.tokenCount) tokens • \(section.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("Keep", isOn: .constant(section.isKept))
                .toggleStyle(.switch)
                .onChange(of: section.isKept) { _ in
                    onToggleKeep()
                }
        }
        .padding(.vertical, 4)
    }
}

struct ContextSection: Identifiable {
    let id: UUID
    let title: String
    let tokenCount: Int
    let timestamp: Date
    var isKept: Bool
}
```

**Effort**: 8 hours

---

### 7.2 Smart Rotation

**Task**: When rotating, keep "pinned" sections and user-marked content.

```swift
actor SmartContextRotator {
    func rotate(
        messages: [Message],
        maxTokens: Int,
        keptSectionIds: Set<UUID>
    ) async -> RotationResult {
        var currentTokens = estimateTokens(messages)
        var rotated: [Message] = []
        var kept: [Message] = []

        for message in messages {
            // Always keep system messages
            if message.role == .system {
                kept.append(message)
                continue
            }

            // Always keep user-pinned sections
            if keptSectionIds.contains(message.id) {
                kept.append(message)
                continue
            }

            // Rotate old messages if over threshold
            if currentTokens > maxTokens * 0.75 {
                rotated.append(message)
                currentTokens -= message.tokenCount
            } else {
                kept.append(message)
            }
        }

        // Create checkpoint for rotated messages
        let checkpoint = await summarizeRotated(rotated)

        return RotationResult(
            kept: kept,
            checkpoint: checkpoint,
            tokensFreed: rotated.reduce(0) { $0 + $1.tokenCount }
        )
    }
}
```

**Effort**: 4 hours

---

**Phase 7 Total**: 12 hours
**Result**: Fine-grained context control, never lose important information

---

## Implementation Summary

### Timeline

| Phase | Description | Effort | Priority |
|-------|-------------|--------|----------|
| **1** | Quick Wins — Integration | 7 hrs | 🔴 Critical |
| **2** | Memory Unification | 6 hrs | 🔴 Critical |
| **3** | Terminal Integration | 12 hrs | 🟡 High |
| **4** | Living Document UI | 24 hrs | 🟡 High |
| **5** | Visual Branching | 16 hrs | 🟢 Medium |
| **6** | Voice Streaming | 16 hrs | 🟢 Medium |
| **7** | Enhanced Compaction | 12 hrs | 🟢 Medium |

**Total Estimated Effort**: 93 hours (~12 days focused work)

### Phased Rollout

**Week 1**: Phases 1-2 (Integration + Memory)
- All systems connected and talking to each other
- Single source of truth for memory
- Telegram fully bidirectional
- **Deliverable**: Unified, cross-device system

**Week 2**: Phase 3 (Terminals)
- Visible terminal integration
- Gateway-managed PTY sessions
- **Deliverable**: TMUX-style terminal visibility

**Week 3**: Phases 4-5 (Living Document + Branching)
- Document-style interface
- Visual branching system
- **Deliverable**: New conversation paradigm

**Week 4**: Phases 6-7 (Voice + Compaction)
- Voice conversation streams
- Fine-grained context control
- **Deliverable**: Complete vision realized

---

## Critical Success Factors

### 1. Start with Quick Wins
The 8-hour integration work (Phase 1) immediately delivers massive value:
- Cross-device sync working
- Telegram reliable
- Unified memory
- Gateway-powered coordination

**Don't skip this.** Everything else builds on it.

### 2. Test Integration Early
After Phase 2, verify:
- Canvas can query gateway memory
- Telegram receives gateway events
- Session hooks load handoffs
- Database migration completed cleanly

### 3. Incremental UI Transition
Phases 4-5 (Living Document + Branching) are the biggest UI changes. Consider:
- Feature flag to toggle between old and new UI
- Run both UIs in parallel during transition
- Gather feedback before full switch

### 4. Voice as Enhancement, Not Blocker
Phase 6 (Voice) is amazing but not critical path. If timeline slips:
- Defer voice to Phase 8
- Focus on core integration and document UI first

---

## Next Steps

1. **Review this plan** — Does the vision align? Any missing pieces?

2. **Choose starting point**:
   - Option A: Start with Phase 1 (8 hours, massive impact)
   - Option B: Prototype living document UI first (validate UX concept)
   - Option C: Fix Telegram integration only (minimal scope)

3. **Set up development environment**:
   - Gateway running locally
   - Canvas debug build
   - Database backups before migration

4. **Kick off Phase 1** — Let's connect these systems.

---

*"The system is closer than it appears. The hard infrastructure exists. The missing piece is connecting what's already built — and then reimagining the interface."*

💠
