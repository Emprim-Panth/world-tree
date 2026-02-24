# FRD-001 — WebSocket Server Extension

**Status:** Draft
**Priority:** Critical (foundation for all mobile features)
**Owner:** Scotty
**Implements:** PRD Core Feature #1, #2, #6

---

## Purpose

Extend World Tree's existing CanvasServer with WebSocket support. The current server handles HTTP/SSE over raw TCP via NWListener. This FRD adds WebSocket upgrade negotiation, persistent bidirectional connections, and a connection management layer. This is the transport foundation — the streaming protocol (FRD-003) builds on top of it.

## User Stories

- As a mobile user, I want a persistent connection to World Tree so I see updates in real time without polling.
- As a mobile user, I want to send messages and receive responses over a single connection without reconnecting per request.
- As a developer, I want WebSocket support integrated into the existing CanvasServer without a separate server process.

## Functional Requirements

**FR-001-001:** CanvasServer SHALL detect WebSocket upgrade requests (HTTP `Upgrade: websocket` header) and perform the RFC 6455 handshake.

**FR-001-002:** WebSocket connections SHALL coexist with existing HTTP/SSE endpoints. Non-WebSocket requests continue to work unchanged.

**FR-001-003:** The server SHALL support multiple concurrent WebSocket connections (minimum 5).

**FR-001-004:** Each WebSocket connection SHALL be tracked with a unique connection ID, connect timestamp, and optional client identifier.

**FR-001-005:** The server SHALL send WebSocket ping frames every 30 seconds. Connections that fail to pong within 10 seconds SHALL be closed.

**FR-001-006:** The server SHALL handle WebSocket close frames gracefully, cleaning up connection state.

**FR-001-007:** The server SHALL support text frames (JSON messages). Binary frames are not required for v1.

**FR-001-008:** Connection state (active connections, IDs) SHALL be observable via `@Published` properties on CanvasServer for the macOS UI to display.

**FR-001-009:** The WebSocket endpoint SHALL be available at `ws://[host]:5865/ws` (same port as existing HTTP server).

**FR-001-010:** The server SHALL authenticate WebSocket connections using the same `x-canvas-token` mechanism — token passed as a query parameter (`?token=xxx`) or in the initial HTTP headers during upgrade.

## Data Requirements

**New state on CanvasServer:**

```swift
struct WebSocketClient {
    let id: String              // UUID
    let connection: NWConnection
    let connectedAt: Date
    var clientName: String?     // Optional identifier from handshake
    var subscribedTreeId: String?
    var subscribedBranchId: String?
    var lastPongAt: Date
}

@Published private(set) var webSocketClients: [String: WebSocketClient] = [:]
```

No database schema changes. WebSocket state is in-memory only.

## Business Rules

- BR-001: WebSocket connections require the same auth token as HTTP endpoints.
- BR-002: Maximum 10 concurrent WebSocket connections (prevents resource exhaustion).
- BR-003: Connections inactive for >5 minutes (no messages, no pong) are terminated.
- BR-004: WebSocket extension must not break existing HTTP/SSE functionality.
- BR-005: All WebSocket operations respect `@MainActor` isolation of CanvasServer.

## Error States

| Error | Response | Recovery |
|-------|----------|----------|
| Missing/invalid token on upgrade | HTTP 401, no upgrade | Client reconnects with valid token |
| Max connections reached | HTTP 503 during upgrade | Client retries with backoff |
| Malformed WebSocket frame | Close connection (code 1002) | Client reconnects |
| Ping timeout (no pong) | Close connection (code 1001) | Client reconnects |
| Server shutdown | Close all connections (code 1001) | Client reconnects when server restarts |

## Acceptance Criteria

1. WebSocket upgrade handshake completes successfully with valid token
2. Messages can be sent bidirectionally over established WebSocket connection
3. Existing HTTP endpoints (`/health`, `/api/sessions`, `/api/messages/:id`, `/api/message`) continue working unchanged
4. Ping/pong keepalive detects and cleans up dead connections
5. Multiple concurrent WebSocket connections work simultaneously
6. macOS UI can observe active WebSocket connection count
7. Connection rejected with 401 when token is missing or invalid

## Out of Scope

- WebSocket Secure (WSS/TLS) — handled at transport level by Tailscale or future TLS addition (FRD-007)
- Message framing protocol — defined in FRD-003
- Bonjour advertising — defined in FRD-002

## Technical Notes

The existing `receiveData` method accumulates TCP bytes and parses HTTP. The WebSocket upgrade check should happen after HTTP header parsing in `handleRawRequest`:

1. Check for `Upgrade: websocket` + `Connection: Upgrade` headers
2. Validate `Sec-WebSocket-Key` and `Sec-WebSocket-Version: 13`
3. Compute `Sec-WebSocket-Accept` response (SHA-1 of key + magic GUID, base64)
4. Send 101 Switching Protocols response
5. Transition connection to WebSocket frame parsing mode

After upgrade, the connection leaves the HTTP request/response pattern and enters WebSocket frame mode. A new `WebSocketConnection` wrapper should handle frame encoding/decoding (opcode, masking, payload length, fragmentation).

Consider extracting this into `Sources/Core/Server/WebSocketHandler.swift` to keep CanvasServer.swift focused on routing.

## Dependencies

- Network framework (NWListener, NWConnection) — already in use
- CommonCrypto or CryptoKit — for SHA-1 in WebSocket handshake
