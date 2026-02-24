# FRD-005 — Conversation UI

**Status:** Draft
**Priority:** High
**Owner:** Scotty / Lumen (design)
**Implements:** PRD Core Features #1, #3, #4
**Depends On:** FRD-003, FRD-004

---

## Purpose

Define the conversation viewing experience on iOS. This is what Ryan looks at most — the tree navigator, branch viewer, and real-time message stream. The key differentiator is live token rendering: text appears as it's generated, like watching someone type in a terminal.

## User Stories

- As a mobile user, I want to browse my conversation trees and see which ones are active.
- As a mobile user, I want to switch between branches within a tree.
- As a mobile user, I want to see LLM responses appear token-by-token in real time.
- As a mobile user, I want to scroll through conversation history easily.
- As a mobile user, I want to see when a tool is being executed.
- As a mobile user, I want to know when a response is complete.

## Functional Requirements

### Tree List

**FR-005-001:** The tree list SHALL display all trees from the server, sorted by `updatedAt` descending.

**FR-005-002:** Each tree entry SHALL show: name, project (if set), last updated relative time, and message count.

**FR-005-003:** Trees with active streaming (LLM currently generating) SHALL show a live indicator.

**FR-005-004:** Pull-to-refresh SHALL re-fetch the tree list from the server.

### Branch Navigator

**FR-005-005:** When a tree is selected, the branch list SHALL display all branches for that tree.

**FR-005-006:** Each branch SHALL show: title, status, message count, and fork point (if branched).

**FR-005-007:** The current/active branch SHALL be highlighted.

**FR-005-008:** Selecting a branch SHALL subscribe to it via WebSocket and load message history.

### Message View

**FR-005-009:** Messages SHALL be displayed in a vertically scrolling list, oldest at top.

**FR-005-010:** User messages SHALL be visually distinct from assistant messages (different background, alignment, or styling).

**FR-005-011:** System messages SHALL be shown as subtle inline dividers.

**FR-005-012:** Messages SHALL support rendered markdown: bold, italic, code inline, code blocks with syntax highlighting, lists, headings, and links.

**FR-005-013:** Code blocks SHALL be horizontally scrollable (not wrapped) with a copy button.

**FR-005-014:** The view SHALL auto-scroll to the bottom when new tokens arrive, UNLESS the user has manually scrolled up.

**FR-005-015:** A "scroll to bottom" FAB SHALL appear when the user is scrolled up and new content arrives.

### Real-Time Streaming

**FR-005-016:** During active streaming, tokens SHALL be appended to a "streaming message" view at the bottom of the message list.

**FR-005-017:** The streaming message SHALL render incrementally — each token appended triggers a UI update. Target: 60fps text rendering.

**FR-005-018:** A typing/streaming indicator SHALL show while tokens are being received (pulsing cursor or animation).

**FR-005-019:** When streaming completes (`message_complete`), the streaming view SHALL transition to a regular message entry.

**FR-005-020:** Tool execution events SHALL display as inline status chips: "[Running: search_files]" → "[Done: search_files]".

**FR-005-021:** If the user opens a branch where streaming is already in progress, they SHALL see tokens from that point forward (not a loading state).

### Performance

**FR-005-022:** Message history SHALL load in pages (50 messages per page). Scroll to top loads previous page.

**FR-005-023:** Token rendering SHALL not drop frames during fast streaming (>100 tokens/sec). Buffer tokens and flush on display link if needed.

**FR-005-024:** Long messages (>5000 chars) SHALL render progressively, not block the UI.

## Data Requirements

**View models (in-memory):**

```swift
struct TreeSummary: Identifiable {
    let id: String
    let name: String
    let project: String?
    let updatedAt: Date
    let messageCount: Int
    var isStreaming: Bool
}

struct BranchSummary: Identifiable {
    let id: String
    let treeId: String
    let title: String
    let status: String
    let messageCount: Int
    let parentBranchId: String?
}

struct Message: Identifiable {
    let id: String
    let role: MessageRole // .user, .assistant, .system
    let content: String
    let createdAt: Date
}
```

## Business Rules

- BR-001: Messages are read-only on iOS (no edit/delete from mobile).
- BR-002: Auto-scroll only engages when user is within 100pt of the bottom.
- BR-003: Markdown rendering is best-effort — malformed markdown degrades gracefully to plain text.
- BR-004: Maximum 500 messages loaded per branch (paginated). Older messages available via scroll.
- BR-005: Tree list refreshes on pull-to-refresh and on `tree_updated` events.

## Error States

| Error | UI Response | Recovery |
|-------|-------------|----------|
| Tree list empty | "No conversations yet" placeholder | Pull to refresh |
| Branch load fails | "Couldn't load branches" with retry | Retry button |
| Message history load fails | "Couldn't load messages" with retry | Retry button |
| Streaming interrupted | Partial message shown with "[interrupted]" | Re-subscribe to branch |
| Markdown render fails | Fall back to plain text | Automatic |

## Acceptance Criteria

1. Tree list loads and displays correctly with sorting and live indicators
2. Branch selection subscribes and loads message history
3. Tokens stream in real time — visible character-by-character append
4. Auto-scroll follows new content; disengages when user scrolls up
5. Markdown renders correctly for code blocks, bold, italic, lists
6. Tool execution shows inline status chips
7. Pagination loads older messages on scroll-to-top
8. 60fps maintained during token streaming

## Out of Scope

- Message search
- Tree/branch creation from iOS
- Tree/branch deletion from iOS
- Message reactions or annotations
- Mermaid diagram rendering (code block only)
- Image/file attachment display

## Technical Notes

### Streaming Text Rendering

The key challenge is appending text at 60fps. Approaches:

**Option A — AttributedString rebuild:** On each token, append to a string and rebuild the AttributedString for markdown. Works for short messages but O(n) per token.

**Option B — Incremental append:** Keep raw text in a buffer. Render markdown only for completed paragraphs. Append raw text for the current line. Re-render current paragraph on line break. Better performance for long messages.

**Option C — CADisplayLink batching:** Accumulate tokens between display frames. Flush all accumulated tokens once per frame (16.6ms). Prevents rendering more often than the display can show. Recommended approach.

### Navigation Structure

```
TabView or NavigationStack:
  TreeListView
    └─ TreeDetailView (branch list)
        └─ ConversationView (messages + streaming)
```

Use `NavigationStack` with path-based navigation for programmatic navigation (restore last-viewed on launch).

### Markdown

Use `swift-markdown-ui` or Apple's `AttributedString(markdown:)` for rendering. Code blocks need custom styling with monospace font and horizontal scroll.
