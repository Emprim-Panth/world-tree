# FRD-003 — Real-Time Streaming Protocol

**Status:** Draft
**Priority:** Critical
**Owner:** Scotty
**Implements:** PRD Core Feature #1
**Depends On:** FRD-001

---

## Purpose

Define the message protocol that runs over WebSocket connections. This is the "Google Wave" layer — how tokens stream in real time, how branches sync, and how the client and server coordinate state. All messages are JSON text frames.

## User Stories

- As a mobile user, I want to see LLM response tokens appear character-by-character as they're generated.
- As a mobile user, I want to see when a tool is being executed during a response.
- As a mobile user, I want to know when another session on the Mac updates a conversation I'm viewing.
- As a mobile user, I want conversation history to load quickly when I switch branches.

## Functional Requirements

### Message Envelope

**FR-003-001:** All WebSocket messages SHALL use this JSON envelope:

```json
{
  "type": "string",
  "id": "string (optional, for request/response correlation)",
  "payload": {}
}
```

### Client → Server Messages

**FR-003-002:** `subscribe` — Subscribe to real-time updates for a tree/branch:

```json
{
  "type": "subscribe",
  "id": "req-1",
  "payload": {
    "treeId": "uuid",
    "branchId": "uuid"
  }
}
```

**FR-003-003:** `unsubscribe` — Stop receiving updates for current subscription:

```json
{
  "type": "unsubscribe",
  "id": "req-2"
}
```

**FR-003-004:** `send_message` — Send a user message to the active branch:

```json
{
  "type": "send_message",
  "id": "req-3",
  "payload": {
    "branchId": "uuid",
    "content": "string"
  }
}
```

**FR-003-005:** `list_trees` — Request available trees:

```json
{
  "type": "list_trees",
  "id": "req-4"
}
```

**FR-003-006:** `list_branches` — Request branches for a tree:

```json
{
  "type": "list_branches",
  "id": "req-5",
  "payload": {
    "treeId": "uuid"
  }
}
```

**FR-003-007:** `get_messages` — Request message history for a branch:

```json
{
  "type": "get_messages",
  "id": "req-6",
  "payload": {
    "branchId": "uuid",
    "limit": 50,
    "before": "message-id (optional, for pagination)"
  }
}
```

### Server → Client Messages

**FR-003-008:** `token` — A single LLM token/chunk during streaming:

```json
{
  "type": "token",
  "payload": {
    "branchId": "uuid",
    "sessionId": "uuid",
    "token": "string (the text chunk)",
    "index": 42
  }
}
```

**FR-003-009:** `message_complete` — Full message finished (after token stream):

```json
{
  "type": "message_complete",
  "payload": {
    "branchId": "uuid",
    "sessionId": "uuid",
    "messageId": "uuid",
    "role": "assistant",
    "content": "full text",
    "tokenCount": 847
  }
}
```

**FR-003-010:** `tool_status` — Tool execution start/end:

```json
{
  "type": "tool_status",
  "payload": {
    "branchId": "uuid",
    "tool": "tool_name",
    "status": "started | completed | error",
    "error": "optional error message"
  }
}
```

**FR-003-011:** `message_added` — A message was added to a subscribed branch (from Mac-side interaction):

```json
{
  "type": "message_added",
  "payload": {
    "branchId": "uuid",
    "messageId": "uuid",
    "role": "user | assistant | system",
    "content": "string",
    "createdAt": "ISO8601"
  }
}
```

**FR-003-012:** `tree_updated` — A tree's metadata changed:

```json
{
  "type": "tree_updated",
  "payload": {
    "treeId": "uuid",
    "name": "string",
    "updatedAt": "ISO8601"
  }
}
```

**FR-003-013:** Response messages for client requests SHALL include the request `id`:

```json
{
  "type": "trees_list",
  "id": "req-4",
  "payload": {
    "trees": [...]
  }
}
```

### Streaming Behavior

**FR-003-014:** When a client subscribes to a branch and an LLM response is in progress, the server SHALL immediately start forwarding tokens from the current position (not replay from beginning).

**FR-003-015:** Token messages SHALL be sent as soon as they're received from the LLM provider — no batching or buffering.

**FR-003-016:** If a client sends a `send_message` while an LLM response is already streaming on that branch, the server SHALL queue the message and respond with an error indicating the branch is busy.

**FR-003-017:** The server SHALL broadcast relevant events to ALL subscribed WebSocket clients for a given branch, not just the one that initiated the request.

## Data Requirements

No database schema changes. The protocol operates on existing TreeStore/MessageStore data.

**In-memory state per WebSocket client:**

```swift
struct ClientSubscription {
    var treeId: String?
    var branchId: String?
    var subscribedAt: Date
}
```

## Business Rules

- BR-001: Clients only receive events for branches they're subscribed to.
- BR-002: A client can only be subscribed to one branch at a time (subscribing to a new one unsubscribes from the previous).
- BR-003: `send_message` requires an active subscription to the target branch.
- BR-004: Token streaming uses the same LLM provider pipeline as existing CanvasServer SSE (reuse, not duplicate).
- BR-005: Message IDs in protocol match database IDs (no translation layer).

## Error States

| Error | Response | Recovery |
|-------|----------|----------|
| Subscribe to non-existent tree/branch | `{"type":"error","id":"req-1","payload":{"code":"not_found"}}` | Client shows error, returns to tree list |
| Send message to unsubscribed branch | `{"type":"error","payload":{"code":"not_subscribed"}}` | Client subscribes first |
| Send message while branch busy | `{"type":"error","payload":{"code":"branch_busy"}}` | Client shows "waiting for response" |
| Invalid message format | `{"type":"error","payload":{"code":"invalid_message"}}` | Client logs, ignores |
| LLM provider error during streaming | `tool_status` with error, then `message_complete` with partial content | Client shows error inline |

## Acceptance Criteria

1. Client subscribes to a branch and receives token-by-token streaming of active LLM response
2. Tokens appear on client within 50ms of server receiving them from LLM provider
3. `send_message` triggers LLM response that streams back to all subscribed clients
4. `list_trees`, `list_branches`, `get_messages` return correct data
5. `tool_status` events appear during tool execution
6. Multiple clients subscribed to the same branch all receive the same token stream
7. Request/response correlation works via `id` field

## Out of Scope

- Binary message support (images, files)
- Message editing or deletion
- Typing indicators from mobile client
- Read receipts
- Compression (future optimization)

## Technical Notes

### Integration with Existing SSE Pipeline

The current `handleMessage` method processes LLM responses via `BridgeEvent` async stream:

```swift
for await event in eventStream {
    case .text(let token): // → sendSSEChunk
    case .done:            // → sendSSEChunk + sendSSEClose
    case .toolStart:       // → sendSSEChunk
    case .toolEnd:         // → sendSSEChunk
}
```

The WebSocket streaming layer should tap into this same event stream. When a message is sent via WebSocket `send_message`, it goes through the same `ProviderManager`/`FridayChannel` pipeline, but tokens are forwarded to WebSocket clients instead of (or in addition to) SSE.

Consider refactoring token delivery into a shared `TokenBroadcaster` that both SSE and WebSocket handlers subscribe to.

### Message Ordering

Token `index` field (FR-003-008) ensures the client can detect and handle out-of-order delivery. Index resets to 0 at the start of each new assistant message.
