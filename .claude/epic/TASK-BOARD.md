# Task Board — World Tree QA

**Last Updated:** 2026-03-11

---

## Legend

- 🔴 **Blocked** — Cannot proceed until blocker resolved
- 🟡 **In Progress** — Actively being worked
- 🔵 **Ready for Review** — Work complete, needs agent sign-off
- 🟢 **Ready** — Approved, ready for next phase
- ✅ **Done** — Complete and merged

---

## 🔴 Blocked

| ID | Title | Assignee | Blocker | Since |
|----|-------|----------|---------|-------|
| | | | | |

---

## 🟡 In Progress

| ID | Title | Assignee | Started | Notes |
|----|-------|----------|---------|-------|
| | | | | |

---

## 🔵 Ready for Review

| ID | Title | Completed By | Reviewer | Submitted |
|----|-------|--------------|----------|-----------|
| | | | | |

---

## 🟢 Ready

### Critical
| ID | Title | Ready Since |
|----|-------|-------------|
| TASK-089 | WebSocket + HTTP server authentication missing | 2026-03-02 |
| TASK-090 | File path traversal in glob/grep/read tools | 2026-03-02 |
| TASK-091 | Orphaned streaming tasks on window close | 2026-03-02 |
| TASK-092 | AppState @State wrapper + silent DB init failure | 2026-03-02 |

### High
| ID | Title | Ready Since |
|----|-------|-------------|
| TASK-094 | Fix test build — codesign script blocks tests | 2026-03-02 |
| TASK-096 | Swallowed errors throughout codebase (try? epidemic) | 2026-03-02 |
| TASK-099 | Edge case crashes — rapid sends, branch delete during stream, fork | 2026-03-02 |
| TASK-114 | Memory leak and retain cycle fixes | 2026-03-11 |
| TASK-115 | Test coverage — critical data layer | 2026-03-11 |
| TASK-118 | Git workflow tools | 2026-03-11 |
| TASK-121 | Job output inspection and streaming | 2026-03-11 |

### Medium
| ID | Title | Ready Since |
|----|-------|-------------|
| TASK-100 | Tool output truncated to 200 chars in UI | 2026-03-02 |
| TASK-101 | UI/UX gaps — loading states, error feedback, confirmation dialogs | 2026-03-02 |
| TASK-102 | Database migration safety issues | 2026-03-02 |
| TASK-103 | Provider pipeline — daemon fallback, tmux leak, cancellation race | 2026-03-02 |
| TASK-104 | Rate limiting bypass behind proxy | 2026-03-11 |
| TASK-105 | Token broadcast to unauthenticated clients | 2026-03-11 |
| TASK-106 | Bash tool injection bypass vectors | 2026-03-11 |
| TASK-107 | Session ID enumeration via API | 2026-03-11 |
| TASK-108 | Search navigation missing from history | 2026-03-11 |
| TASK-109 | Accessibility gaps — full remediation | 2026-03-11 |
| TASK-116 | Test coverage — high priority service layer | 2026-03-11 |
| TASK-117 | Stress test plan | 2026-03-11 |
| TASK-120 | iOS simulator tools | 2026-03-11 |
| TASK-122 | Auto-decision logging in memory | 2026-03-11 |
| TASK-123 | Starfleet agent invocation wiring | 2026-03-11 |
| TASK-124 | Compass write integration | 2026-03-11 |

### Low
| ID | Title | Ready Since |
|----|-------|-------------|
| TASK-110 | Force-unwrap in GatewayClient fallback URL | 2026-03-11 |
| TASK-111 | GraphStore FNV-1a hash collision potential | 2026-03-11 |
| TASK-112 | HeartbeatStore reads non-existent tables | 2026-03-11 |
| TASK-113 | Empty-state handling gaps | 2026-03-11 |
| TASK-119 | Code analysis tools | 2026-03-11 |
| TASK-125 | Branch export and sharing | 2026-03-11 |
| TASK-126 | Auto-naming branches | 2026-03-11 |

---

## ✅ Done

| ID | Title | Completed | Notes |
|----|-------|-----------|-------|
| TASK-001 | WebSocket upgrade handshake in CanvasServer | 2026-02-23 | |
| TASK-002 | WebSocket frame parser (encode/decode) | 2026-02-23 | |
| TASK-003 | WebSocket connection manager + lifecycle | 2026-02-23 | |
| TASK-004 | Bonjour service advertising on macOS | 2026-02-23 | |
| TASK-005 | Protocol message types + JSON serialization | 2026-02-23 | |
| TASK-006 | Server-side WebSocket message dispatcher | 2026-02-23 | |
| TASK-007 | Token broadcaster (LLM events → WebSocket clients) | 2026-02-23 | |
| TASK-008 | Subscription manager (client → branch mapping) | 2026-02-23 | |
| TASK-009 | iOS project scaffold (WorldTreeMobile) | 2026-02-23 | |
| TASK-010 | ConnectionManager (WebSocket client + reconnect) | 2026-02-23 | |
| TASK-011 | WorldTreeStore (state management) | 2026-02-23 | |
| TASK-012 | KeychainHelper for iOS token storage | 2026-02-23 | |
| TASK-013 | iOS Bonjour browser + server picker UI | 2026-02-23 | |
| TASK-014 | Tailscale manual address entry + persistence | 2026-02-23 | |
| TASK-015 | iOS Settings screen | 2026-02-23 | |
| TASK-016 | Tree list view (iOS) | 2026-02-23 | |
| TASK-017 | Branch navigator view (iOS) | 2026-02-23 | |
| TASK-018 | Message list view with markdown rendering | 2026-02-23 | |
| TASK-019 | Real-time streaming view (60fps token rendering) | 2026-02-23 | |
| TASK-020 | Tool execution status chips in conversation | 2026-02-23 | |
| TASK-021 | Message input bar (multi-line + keyboard avoidance) | 2026-02-23 | |
| TASK-022 | Send/stop behavior + optimistic UI | 2026-02-23 | |
| TASK-023 | Draft persistence per branch | 2026-02-23 | |
| TASK-024 | Server-side cancel_stream support | 2026-02-23 | |
| TASK-025 | Token validation on WebSocket upgrade | 2026-02-23 | |
| TASK-026 | Rate limiting for failed auth attempts | 2026-02-23 | |
| TASK-027 | Token regeneration UI on macOS | 2026-02-23 | |
| TASK-028 | Session persistence + last-viewed restore | 2026-02-23 | |
| TASK-029 | Fix mobile client ↔ server protocol mismatch | 2026-02-24 | |
| TASK-030 | Fix Bonjour service type mismatch | 2026-02-24 | |
| TASK-031 | Add error type handler to WorldTreeStore | 2026-02-23 | |
| TASK-032 | Fix repeated macOS permission requests | 2026-02-24 | |
| TASK-033 | Codebase audit — stability, memory, and efficiency pass | 2026-02-24 | 6c1533c |
| TASK-034 | Optimize message pipeline latency | 2026-02-24 | |
| TASK-035 | Conversation-level RAG: context scorer + search_conversation | 2026-02-24 | |
| TASK-036 | UI/UX improvements — Lumen design review pass | 2026-02-24 | |
| TASK-037 | Fourth audit pass: C-1 through L-5 fixes | 2026-02-24 | ac2e264 |
| TASK-038 | Wire branch fork display | 2026-02-24 | |
| TASK-039 | Wire SessionRotator into streaming pipeline | 2026-02-24 | |
| TASK-040 | Pass 5 audit fixes — C-1 through M-10 | 2026-02-24 | 4f0c55b |
| TASK-041 | Fix 3 UI bugs: project sort, sent message missing, input box height | 2026-02-25 | |
| TASK-042 | Add paragraph formatting directive to CortanaIdentity | 2026-02-25 | |
| TASK-043 | Remove CortanaConstants — rename to AppConstants | 2026-02-25 | |
| TASK-044 | Add sidebar sort picker | 2026-02-25 | |
| TASK-045 | Fix sidebar sort button visibility and sort order | 2026-02-25 | |
| TASK-046 | Fix auto-scroll | 2026-02-25 | |
| TASK-047 | Fix scroll to bottom on conversation open | 2026-03-01 | |
| TASK-048 | Add search bar and sort picker to SimpleModeView | 2026-02-25 | |
| TASK-049 | Fix conversation scroll behind input box | 2026-03-01 | |
| TASK-050 | Fix session resume on app restart | 2026-03-02 | |
| TASK-051 | Fix canvas-sessions.json timestamps | 2026-03-02 | |
| TASK-052 | Snapshot checkpoint after each response | 2026-03-02 | |
| TASK-053 | Relax snapshot checkpoint guard | 2026-03-02 | |
| TASK-054 | Extend checkpoint TTL for multi-day sessions | 2026-03-02 | |
| TASK-055 | iPhone search in tree/branch list | 2026-03-03 | |
| TASK-056 | Tree/branch management on mobile | 2026-03-03 | |
| TASK-057 | iOS offline support (GRDB local cache) | 2026-03-03 | |
| TASK-058 | iOS Live Activities & Dynamic Island | 2026-03-03 | |
| TASK-059 | Siri & Shortcuts integration | 2026-03-03 | |
| TASK-060 | Share Extension | 2026-03-03 | |
| TASK-061 | Handoff / Continuity | 2026-03-03 | |
| TASK-062 | Notification Reply | 2026-03-03 | |
| TASK-063 | Widgets (WidgetKit) | 2026-03-03 | |
| TASK-064 | Voice mode | 2026-03-03 | |
| TASK-065 | Apple Watch companion | 2026-03-03 | |
| TASK-066 | Spatial computing / visionOS | 2026-03-03 | |
| TASK-067 | PencilMCPClient — HTTP MCP client | 2026-03-10 | |
| TASK-068 | PencilModels — Swift types for .pen schema | 2026-03-10 | |
| TASK-069 | PencilConnectionStore — observable connection state | 2026-03-10 | |
| TASK-070 | Design Tab in Command Center | 2026-03-10 | |
| TASK-071 | Settings — Pencil MCP URL config | 2026-03-10 | |
| TASK-072 | Worf — Phase 1 MCP client tests | 2026-03-10 | |
| TASK-073 | Dax — Phase 1 knowledge capture | 2026-03-10 | |
| TASK-074 | DB Migration v22 — pen_assets tables | 2026-03-10 | |
| TASK-075 | PenAssetStore — CRUD for .pen assets | 2026-03-10 | |
| TASK-076 | .pen File Inspector UI | 2026-03-10 | |
| TASK-077 | Ticket detail — design frames section | 2026-03-10 | |
| TASK-078 | Worf — Phase 2 asset import tests | 2026-03-10 | |
| TASK-079 | Three new MCP tools in PluginServer | 2026-03-10 | |
| TASK-080 | PluginServer manifest update | 2026-03-10 | |
| TASK-081 | Worf — Phase 3 integration tests | 2026-03-10 | |
| TASK-082 | Dax — Phase 3 MCP tool contracts | 2026-03-10 | |
| TASK-083 | Filesystem watcher for .pen files | 2026-03-10 | |
| TASK-084 | Frame screenshot export | 2026-03-10 | |
| TASK-085 | Frame preview panel | 2026-03-10 | |
| TASK-086 | Visual diff — Pencil frame vs running app | 2026-03-10 | |
| TASK-087 | world_tree_frame_screenshot MCP tool | 2026-03-10 | |
| TASK-088 | Phase 4 docs update | 2026-03-10 | |
| TASK-093 | Race conditions in ClaudeCodeProvider | 2026-03-11 | NSLock stateLock/mapLock |
| TASK-095 | Message hasBranches Int64 cast fix | 2026-03-11 | ffc6d45 |
| TASK-097 | UI lifecycle — observer cleanup | 2026-03-11 | Deep inspect cycles |
| TASK-098 | Database trigger + query perf | 2026-03-11 | Migration 17 denormalization |

---

## Quick Stats

| Status | Count |
|--------|-------|
| Blocked | 0 |
| In Progress | 0 |
| Ready for Review | 0 |
| Ready | 34 |
| Done | 92 |
| **Total** | **126** |

### Ready by Priority
| Priority | Count |
|----------|-------|
| Critical | 4 |
| High | 7 |
| Medium | 16 |
| Low | 7 |

---

*Updated 2026-03-11 by Cortana*
