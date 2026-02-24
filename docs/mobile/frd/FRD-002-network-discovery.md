# FRD-002 — Network Discovery (Bonjour + Tailscale)

**Status:** Draft
**Priority:** High
**Owner:** Scotty
**Implements:** PRD Core Feature #5
**Depends On:** FRD-001

---

## Purpose

Enable the iOS client to find World Tree's server automatically. Bonjour handles zero-config discovery on the local network. Tailscale handles remote access when not on the same network. Together they cover every connectivity scenario without manual IP entry.

## User Stories

- As a mobile user on my home network, I want my iPhone to automatically find World Tree without entering an IP address.
- As a mobile user away from home, I want to connect to World Tree through Tailscale without additional configuration.
- As a mobile user, I want to see the server's availability status before attempting to connect.

## Functional Requirements

### Bonjour (macOS Server Side)

**FR-002-001:** When CanvasServer starts, it SHALL advertise a Bonjour service of type `_worldtree._tcp.` on the local network.

**FR-002-002:** The Bonjour service SHALL advertise on the same port as CanvasServer (5865).

**FR-002-003:** The TXT record SHALL include:
- `version` — Protocol version (e.g., "1")
- `name` — Machine hostname or user-configured server name
- `wsPath` — WebSocket path (e.g., "/ws")

**FR-002-004:** When CanvasServer stops, the Bonjour service SHALL be unregistered.

**FR-002-005:** Bonjour advertising SHALL be enabled/disabled via a UserDefaults toggle (`cortana.bonjourEnabled`), defaulting to enabled.

### Bonjour (iOS Client Side)

**FR-002-006:** The iOS client SHALL browse for `_worldtree._tcp.` services on the local network.

**FR-002-007:** Discovered services SHALL be displayed in a server picker with the advertised name and resolved IP/port.

**FR-002-008:** The client SHALL resolve Bonjour services to IP addresses before attempting connection.

**FR-002-009:** If multiple servers are discovered, all SHALL be listed. The most recently connected server is highlighted.

### Tailscale

**FR-002-010:** The iOS client SHALL support manual entry of a Tailscale hostname or IP (e.g., `ryans-mac.tail12345.ts.net:5865`).

**FR-002-011:** The client SHALL store saved Tailscale addresses for quick reconnection.

**FR-002-012:** The client SHALL attempt to detect Tailscale availability by checking for a Tailscale VPN interface (optional, best-effort).

### Connection Selection

**FR-002-013:** The server picker SHALL show both Bonjour-discovered and saved Tailscale servers in a unified list.

**FR-002-014:** Each server entry SHALL show: name, address, connection type (Local/Tailscale), and last-connected timestamp.

**FR-002-015:** The client SHALL auto-connect to the last-used server on app launch if available.

## Data Requirements

**iOS client storage (UserDefaults or Keychain):**

```swift
struct SavedServer: Codable {
    let id: String           // UUID
    var name: String         // Display name
    var host: String         // IP or hostname
    var port: UInt16         // Default 5865
    var source: DiscoverySource // .bonjour | .tailscale | .manual
    var token: String        // Auth token (stored in Keychain)
    var lastConnected: Date?
}
```

**macOS — no schema changes.** Bonjour state is in-memory.

## Business Rules

- BR-001: Bonjour discovery is local network only — never exposes the server beyond the LAN.
- BR-002: Tailscale addresses are user-entered, not auto-discovered (Tailscale handles its own discovery).
- BR-003: Auth token must be configured per server — Bonjour discovery does not transmit the token.
- BR-004: Server name in Bonjour TXT record uses `Host.current().localizedName` unless overridden in settings.

## Error States

| Error | Response | Recovery |
|-------|----------|----------|
| No Bonjour services found | Show "No servers found on local network" | Manual entry option always available |
| Bonjour resolve fails | Show error inline, allow retry | Re-browse or enter IP manually |
| Tailscale not running | Connection timeout | Prompt user to check Tailscale status |
| Port blocked/filtered | Connection timeout | Inform user, suggest checking firewall |

## Acceptance Criteria

1. CanvasServer advertises Bonjour service on start and removes it on stop
2. iOS client discovers World Tree server within 3 seconds on local network
3. Bonjour TXT record includes protocol version and WebSocket path
4. Manual Tailscale address entry works and persists across app launches
5. Auto-connect to last-used server works on app launch
6. Multiple discovered servers displayed correctly in picker

## Out of Scope

- Tailscale auto-detection of peer machines (use manual address entry)
- mDNS relay across subnets (standard Bonjour limitation)
- Server-side Tailscale API integration
- QR code pairing (future enhancement)

## Technical Notes

### macOS Bonjour Implementation

Use `NWListener` built-in Bonjour advertising:

```swift
let params = NWParameters.tcp
let listener = try NWListener(using: params, on: 5865)
listener.service = NWListener.Service(
    name: Host.current().localizedName ?? "World Tree",
    type: "_worldtree._tcp.",
    txtRecord: makeTXTRecord()
)
```

`NWListener` handles advertising automatically when `.service` is set. This integrates cleanly with the existing CanvasServer setup.

### iOS Bonjour Implementation

Use `NWBrowser`:

```swift
let browser = NWBrowser(for: .bonjour(type: "_worldtree._tcp.", domain: nil), using: .tcp)
browser.browseResultsChangedHandler = { results, changes in
    // Update discovered servers list
}
browser.start(queue: .main)
```

### iOS Info.plist

Add `NSBonjourServices` with `_worldtree._tcp.` and `NSLocalNetworkUsageDescription`.
