# FRD-004 — iOS Client Foundation

**Status:** Draft
**Priority:** High
**Owner:** Scotty
**Implements:** PRD Core Features #5, #6, #7
**Depends On:** FRD-001, FRD-002

---

## Purpose

Define the iOS app structure, connection management, and foundational architecture. This is the skeleton that all UI features (FRD-005, FRD-006) build on. Covers project setup, networking layer, state management, and settings.

## User Stories

- As a mobile user, I want the app to connect to my Mac quickly and show me the connection status.
- As a mobile user, I want to switch between servers if I have multiple Macs or configurations.
- As a mobile user, I want the app to reconnect automatically if my network drops temporarily.
- As a mobile user, I want my last-viewed conversation to appear when I reopen the app.

## Functional Requirements

### Project Structure

**FR-004-001:** The iOS app SHALL be a new Xcode project named `WorldTreeMobile` inside the `world-tree` repository under `Mobile/`.

**FR-004-002:** Minimum deployment target: iOS 17.0.

**FR-004-003:** The app SHALL use SwiftUI exclusively. No UIKit view controllers.

**FR-004-004:** Architecture: single-app target. No frameworks or packages for v1. Shared protocol types extracted if needed.

### Connection Manager

**FR-004-005:** A `ConnectionManager` (ObservableObject) SHALL manage the WebSocket lifecycle:

```swift
@Observable
final class ConnectionManager {
    enum State {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    var state: State
    var currentServer: SavedServer?
    var latency: TimeInterval? // Last ping round-trip
}
```

**FR-004-006:** `ConnectionManager` SHALL use `URLSessionWebSocketTask` for WebSocket communication.

**FR-004-007:** On connection loss, the manager SHALL automatically reconnect with exponential backoff: 1s, 2s, 4s, 8s, max 30s. Maximum 10 attempts before giving up.

**FR-004-008:** The manager SHALL respond to WebSocket ping frames from the server.

**FR-004-009:** The manager SHALL measure and expose connection latency (ping round-trip time).

**FR-004-010:** The manager SHALL handle app backgrounding: disconnect after 30 seconds in background, reconnect on foreground.

### State Management

**FR-004-011:** App state SHALL be managed via `@Observable` classes, not Combine publishers.

**FR-004-012:** A `WorldTreeStore` SHALL hold the current tree/branch lists and messages received from the server:

```swift
@Observable
final class WorldTreeStore {
    var trees: [TreeSummary] = []
    var currentTree: TreeSummary?
    var branches: [BranchSummary] = []
    var currentBranch: BranchSummary?
    var messages: [Message] = []
    var streamingText: String = "" // Current in-progress response
    var isStreaming: Bool = false
}
```

**FR-004-013:** `WorldTreeStore` SHALL process incoming WebSocket messages and update state accordingly.

**FR-004-014:** The store SHALL maintain message ordering using the `index` field from token events.

### Session Persistence

**FR-004-015:** The last-connected server ID SHALL persist in UserDefaults.

**FR-004-016:** The last-viewed tree and branch IDs SHALL persist in UserDefaults.

**FR-004-017:** On launch, the app SHALL auto-connect to the last server and navigate to the last branch.

**FR-004-018:** Auth tokens SHALL be stored in the iOS Keychain, not UserDefaults.

### Settings

**FR-004-019:** A Settings screen SHALL provide:
- Server management (add/edit/remove saved servers)
- Connection preferences (auto-connect on/off)
- Display preferences (font size for messages)

**FR-004-020:** Server list SHALL show connection status indicator (green/yellow/red) for each saved server.

## Data Requirements

**Local persistence (iOS side):**

```swift
// UserDefaults
"lastServerId": String
"lastTreeId": String
"lastBranchId": String
"autoConnect": Bool (default: true)
"messageFontSize": Double (default: 15.0)

// Keychain
"server.{id}.token": String // Per-server auth token
```

**No local database.** All conversation data lives on the Mac. The iOS client is a remote viewer.

## Business Rules

- BR-001: The app has no offline functionality. It shows "Not Connected" when disconnected.
- BR-002: Only one server connection at a time.
- BR-003: Auth tokens never leave the Keychain. Never logged or transmitted except in WebSocket upgrade.
- BR-004: Reconnection stops after 10 failed attempts. User must manually retry.
- BR-005: App must work on iPhone SE screen size (375pt width minimum).

## Error States

| Error | UI Response | Recovery |
|-------|-------------|----------|
| No saved servers | Show server setup screen | User adds server via Bonjour or manual entry |
| Connection refused | "Server unreachable" with server name | Retry button + check server status |
| Auth failed (401 on upgrade) | "Invalid token" | Prompt to re-enter token in settings |
| Network lost mid-session | Yellow "Reconnecting..." banner | Auto-reconnect with backoff |
| Reconnection exhausted (10 attempts) | Red "Disconnected" banner | Manual "Reconnect" button |
| App returns from background | Transparent reconnect | Auto-reconnect, re-subscribe to last branch |

## Acceptance Criteria

1. App launches, discovers server via Bonjour, connects via WebSocket
2. Connection state visible in UI at all times (connected/reconnecting/disconnected)
3. Auto-reconnect recovers from brief network interruptions without user action
4. Last-viewed tree/branch restored on app launch
5. Settings screen allows adding servers manually (Tailscale address)
6. Auth token stored securely in Keychain
7. App handles background/foreground transitions cleanly

## Out of Scope

- Local database / offline caching
- Push notifications for new messages
- Widget / Live Activity
- watchOS companion
- Shared Xcode project with macOS target (separate project for v1)

## Technical Notes

### Project Placement

```
world-tree/
├── Sources/         # macOS app (existing)
├── Mobile/          # NEW — iOS app
│   ├── WorldTreeMobile/
│   │   ├── App/
│   │   │   └── WorldTreeMobileApp.swift
│   │   ├── Core/
│   │   │   ├── ConnectionManager.swift
│   │   │   ├── WorldTreeStore.swift
│   │   │   ├── MessageParser.swift
│   │   │   └── KeychainHelper.swift
│   │   ├── Features/
│   │   │   ├── ServerPicker/
│   │   │   ├── Conversation/
│   │   │   └── Settings/
│   │   └── Shared/
│   │       ├── Models.swift     # TreeSummary, BranchSummary, Message
│   │       └── Constants.swift
│   └── WorldTreeMobile.xcodeproj
└── docs/
```

### Shared Types

Consider a `Shared/` directory at the repo root for types used by both macOS and iOS (tree/branch/message models, protocol message types). For v1, duplicating is acceptable to avoid multi-platform build complexity.

### URLSessionWebSocketTask

```swift
let url = URL(string: "ws://\(server.host):\(server.port)/ws?token=\(token)")!
let task = URLSession.shared.webSocketTask(with: url)
task.resume()

// Receive loop
func receiveLoop() {
    task.receive { result in
        switch result {
        case .success(.string(let text)):
            self.handleMessage(text)
        case .failure(let error):
            self.handleDisconnect(error)
        default: break
        }
        self.receiveLoop() // Continue receiving
    }
}
```
