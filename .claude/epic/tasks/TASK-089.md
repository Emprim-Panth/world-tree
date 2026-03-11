# TASK-089: CRITICAL — WebSocket + HTTP server authentication missing

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** Auth enforcement on PeekabooBridge (per-fd tracking) + WorldTreeServer (HTTP header + WS auth message + 10s timeout)
**Priority:** critical
**Assignee:** —
**Phase:** Security
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Both the WebSocket server (port 5866) and HTTP API server (port 5865) have **no authentication enforcement**. The infrastructure exists (token parsing, rate limiter) but is never validated against incoming requests.

### WebSocket (port 5866)
- Comment at line 1418 of WorldTreeServer.swift says "first message must be auth" — **never implemented**
- Any client can connect and call `listTrees`, `getMessages`, `sendMessage`, `deleteTree` etc.
- All conversation data is fully exposed to anyone on the network

### HTTP API (port 5865)
- `x-worldtree-token` header is parsed (line 808) but **never validated**
- All `/api/*` endpoints are unauthenticated
- POST /api/message allows arbitrary message injection
- GET /api/sessions lists all conversations

### Impact
- Complete data breach of all conversation history
- Arbitrary message injection into any conversation
- If exposed via ngrok/Tailscale, internet-accessible without auth

## Acceptance Criteria

- [ ] WebSocket: First message must be `{"type":"auth","token":"<token>"}` with 10s timeout
- [ ] WebSocket: All handlers gated behind `client.authenticated` check
- [ ] HTTP: All `/api/*` endpoints validate `x-worldtree-token` header
- [ ] HTTP: Return 401 for missing/invalid tokens
- [ ] Rate limiting applied to both WebSocket auth and HTTP auth failures
- [ ] Existing mobile app updated to send auth token

## Files

- `Sources/Core/Server/WorldTreeServer.swift` (lines 903-954, 377-396, 1418, 1522-1558)
- `Sources/Core/Server/AuthRateLimiter.swift`
