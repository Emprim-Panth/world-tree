# World Tree Mobile — Product Requirements Document

**Version:** 1.0
**Date:** 2026-02-22
**Status:** Draft
**Author:** Friday

---

## Problem Statement

World Tree is a desktop-only macOS app. Ryan needs to interact with his conversation trees from his iPhone — reading live responses as they stream, sending messages, and navigating branches — without being tethered to his Mac. The existing CanvasServer provides HTTP/SSE for Telegram integration, but lacks the bidirectional real-time transport needed for a native mobile experience.

## Solution Overview

Extend World Tree's existing CanvasServer with WebSocket support for persistent, bidirectional real-time communication. Add Bonjour for zero-config local discovery and Tailscale for remote access. Build a native iOS client that connects to the Mac and provides a live terminal-style view of conversations — tokens appear as they're generated, Google Wave style.

This is **not** a standalone app. It's a remote viewer/controller for World Tree running on the Mac. The Mac remains the source of truth for all data and LLM execution.

## Target Users

**Primary:** Ryan — accessing World Tree conversations from iPhone while away from desk, in another room, or on the go.

**Secondary:** Any World Tree user who wants mobile access to their conversation trees.

## Platform & Distribution

- **Server side:** macOS (embedded in World Tree, extends existing CanvasServer)
- **Client side:** iOS 17.0+ (iPhone). iPad support via iPhone compatibility initially.
- **Distribution:** Direct install (no App Store for v1). TestFlight if needed.
- **Pricing:** N/A — personal tool.

## Core Features (MVP)

Ranked by value:

1. **Real-time message streaming** — See LLM tokens appear live as they're generated (terminal/Wave style)
2. **Send messages** — Compose and send prompts to active conversations from iPhone
3. **Tree & branch navigation** — Browse conversation trees, switch between branches
4. **Read conversation history** — Scroll through past messages in any branch
5. **Automatic discovery** — Bonjour finds World Tree on local network; Tailscale works remotely
6. **Connection management** — Connect, disconnect, reconnect gracefully. Show connection status.
7. **Session continuity** — Pick up where you left off. Last-viewed tree/branch persists.

## Out of Scope (v1.0)

- **Offline mode / local caching** — No local database on iOS. Always connected.
- **Creating new trees** — v1 browses and continues existing trees only.
- **Branch creation/forking** — v1 follows existing branch structure.
- **Tool execution UI** — Tool calls shown as status indicators, not interactive.
- **File attachments / image upload** — Text-only messaging.
- **Voice input** — Standard iOS keyboard only.
- **Push notifications** — No background notification of new messages.
- **Multiple Mac connections** — One Mac target at a time.
- **App Store submission** — Direct install / TestFlight only.
- **iPad-native layout** — iPhone layout scales; no split-view optimization.

## Success Metrics

- **Functional:** Can send a message from iPhone and see streamed response in <500ms first-token latency (local network)
- **Usable:** Full conversation readable and navigable on iPhone screen
- **Reliable:** Reconnects automatically after network interruption within 5s
- **Discovery:** Bonjour finds server within 3s on local network

## Constraints & Assumptions

**Constraints:**
- CanvasServer is `@MainActor` singleton — WebSocket extension must respect this
- NWListener (Network framework) is the transport layer — no third-party HTTP frameworks
- Shared SQLite database (GRDB, WAL mode) — no schema-breaking changes
- iOS client must work with existing TreeStore/MessageStore data model

**Assumptions:**
- Mac running World Tree is always the server (never the iOS device)
- Tailscale is already installed and configured on both devices
- Local network allows mDNS/Bonjour traffic (most home networks do)
- WebSocket upgrade can be implemented atop existing NWListener TCP handling

## Dependencies

- **Network framework** (Apple) — Already in use for CanvasServer
- **GRDB.swift** — Already in use for persistence
- **Bonjour/mDNS** — Apple framework, no external dependency
- **Tailscale** — External app, assumed pre-installed
- **SwiftUI** — iOS client framework

## Timeline (rough)

| Phase | Scope | Estimate |
|-------|-------|----------|
| 1 | WebSocket server + streaming protocol | Foundation |
| 2 | Bonjour discovery + Tailscale docs | Parallel with Phase 1 |
| 3 | iOS client foundation + connection | After Phase 1 |
| 4 | Conversation UI + real-time rendering | After Phase 3 |
| 5 | Input, interaction, polish | After Phase 4 |
| 6 | Security hardening + QA | After Phase 5 |

## FRD Index

| FRD | Area | Depends On |
|-----|------|------------|
| [FRD-001](frd/FRD-001-websocket-server.md) | WebSocket Server Extension | — |
| [FRD-002](frd/FRD-002-network-discovery.md) | Network Discovery (Bonjour + Tailscale) | FRD-001 |
| [FRD-003](frd/FRD-003-realtime-streaming.md) | Real-Time Streaming Protocol | FRD-001 |
| [FRD-004](frd/FRD-004-ios-client-core.md) | iOS Client Foundation | FRD-001, FRD-002 |
| [FRD-005](frd/FRD-005-conversation-ui.md) | Conversation UI | FRD-003, FRD-004 |
| [FRD-006](frd/FRD-006-input-interaction.md) | Message Input & Interaction | FRD-004, FRD-005 |
| [FRD-007](frd/FRD-007-auth-security.md) | Authentication & Security | FRD-001 |
