# FRD-006 — Message Input & Interaction

**Status:** Draft
**Priority:** Medium
**Owner:** Scotty
**Implements:** PRD Core Feature #2
**Depends On:** FRD-004, FRD-005

---

## Purpose

Define how users compose and send messages from the iOS client. This covers the input UI, send behavior, and interaction patterns. Messaging should feel natural and responsive — send a prompt, watch the response stream back.

## User Stories

- As a mobile user, I want to type a message and send it to the current conversation.
- As a mobile user, I want to see my message appear immediately after sending.
- As a mobile user, I want to know if my message failed to send.
- As a mobile user, I want to cancel a streaming response if it's going in the wrong direction.

## Functional Requirements

### Input Bar

**FR-006-001:** A message input bar SHALL be pinned to the bottom of the conversation view, above the keyboard.

**FR-006-002:** The input bar SHALL contain a multi-line text field and a send button.

**FR-006-003:** The text field SHALL grow vertically to accommodate up to 5 lines of text, then scroll internally.

**FR-006-004:** The send button SHALL be disabled when the text field is empty or when the branch is busy (streaming).

**FR-006-005:** The send button SHALL be replaced with a stop button while a response is streaming.

### Send Behavior

**FR-006-006:** Tapping send SHALL:
1. Immediately display the user message in the conversation (optimistic UI)
2. Send the `send_message` WebSocket message to the server
3. Clear the input field
4. Scroll to bottom

**FR-006-007:** If the server returns an error for `send_message`, the user message SHALL show an error state with a retry option.

**FR-006-008:** The keyboard return key SHALL insert a newline. A dedicated send button handles submission (no return-to-send).

### Stop/Cancel

**FR-006-009:** While a response is streaming, tapping the stop button SHALL send a `cancel_stream` message to the server:

```json
{
  "type": "cancel_stream",
  "payload": {
    "branchId": "uuid"
  }
}
```

**FR-006-010:** The server SHALL stop the LLM generation and send a `message_complete` with the partial response.

**FR-006-011:** The partial response SHALL be persisted as a regular message (content up to cancellation point).

### Input State

**FR-006-012:** Draft text SHALL persist per branch — switching branches saves the current draft and restores the previous one.

**FR-006-013:** Draft text SHALL survive app backgrounding.

**FR-006-014:** The input bar SHALL show the current branch name as placeholder text when empty.

## Data Requirements

**In-memory draft storage:**

```swift
// Keyed by branchId
var drafts: [String: String] = [:]
```

Persisted to UserDefaults on background, restored on foreground.

**Server-side (cancel_stream):**

The server needs to support cancelling an in-progress LLM generation. This maps to cancelling the `AsyncStream<BridgeEvent>` task in CanvasServer's message handler.

## Business Rules

- BR-001: Only one message can be "in flight" per branch (no rapid-fire sends while streaming).
- BR-002: Empty or whitespace-only messages are not sendable.
- BR-003: No character limit on messages (server may impose limits, but client doesn't).
- BR-004: Cancel is best-effort — the LLM may complete before cancellation reaches the provider.
- BR-005: Optimistic UI: user message appears immediately. If send fails, message shows error state.

## Error States

| Error | UI Response | Recovery |
|-------|-------------|----------|
| Send fails (network) | User message shows red indicator + "Failed to send" | Tap to retry |
| Send fails (branch busy) | Toast: "Waiting for current response" | Auto-send when response completes, or user cancels |
| Cancel fails | Stop button returns to normal; streaming continues | Wait for response to complete naturally |
| Connection lost while composing | Draft preserved; "Disconnected" banner | Reconnect sends draft on user action |

## Acceptance Criteria

1. User can type and send a message; it appears immediately in conversation
2. Send button disabled during streaming; stop button shown instead
3. Stop button cancels streaming and shows partial response
4. Draft text persists across branch switches
5. Failed sends show error state with retry
6. Return key inserts newline; dedicated send button submits
7. Input bar properly avoids keyboard (no overlap)

## Out of Scope

- Voice input / dictation (use standard iOS keyboard dictation)
- Image or file attachments
- Message templates or shortcuts
- Slash commands
- Edit or delete sent messages
- Swipe gestures on messages

## Technical Notes

### Cancel Stream Server-Side

Add `cancel_stream` handling to CanvasServer's WebSocket message dispatcher. This needs to:

1. Find the active `Task` running the LLM stream for the given branch
2. Cancel it (`task.cancel()`)
3. The `for await event in eventStream` loop will exit
4. Persist partial response and send `message_complete`

This requires tracking active streaming tasks per branch:

```swift
private var activeStreamTasks: [String: Task<Void, Never>] = [:] // branchId → task
```

### Keyboard Avoidance

Use `.scrollDismissesKeyboard(.interactively)` on the message scroll view. The input bar should use `.safeAreaInset(edge: .bottom)` to properly position above the keyboard.
