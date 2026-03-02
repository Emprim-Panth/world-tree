# Task Board — Epic on main

**Epic:** Epic on main
**Last Updated:** 2026-03-02

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

| ID | Title | Approved By | Ready Since |
|----|-------|-------------|-------------|
| TASK-050 | fix: session resume broken on app restart — missing timestamp from DB load | — | 2026-03-02 |
| TASK-051 | fix: canvas-sessions.json loses timestamps — add SessionEntry format with lastUsed | — | 2026-03-02 |
| TASK-052 | fix: snapshot checkpoint only written on onDisappear — write after each response | — | 2026-03-02 |
| TASK-053 | fix: snapshot checkpoint guard requires >=4 sections — misses short conversations | — | 2026-03-02 |
| TASK-054 | fix: checkpoint TTL 24h too short for multi-day sessions | — | 2026-03-02 |

---

## ✅ Done

| ID | Title | Completed | Final Sign-off |
|----|-------|-----------|----------------|
| TASK-001 | WebSocket upgrade handshake in CanvasServer | 2026-02-23 | — |
| TASK-002 | WebSocket frame parser (encode/decode) | 2026-02-23 | — |
| TASK-003 | WebSocket connection manager + lifecycle | 2026-02-23 | — |
| TASK-004 | Bonjour service advertising on macOS | 2026-02-23 | — |
| TASK-005 | Protocol message types + JSON serialization | 2026-02-23 | — |
| TASK-006 | Server-side WebSocket message dispatcher | 2026-02-23 | — |
| TASK-007 | Token broadcaster (LLM events → WebSocket clients) | 2026-02-23 | — |
| TASK-008 | Subscription manager (client → branch mapping) | 2026-02-23 | — |
| TASK-009 | iOS project scaffold (WorldTreeMobile) | 2026-02-23 | — |
| TASK-010 | ConnectionManager (WebSocket client + reconnect) | 2026-02-23 | — |
| TASK-011 | WorldTreeStore (state management) | 2026-02-23 | — |
| TASK-012 | KeychainHelper for iOS token storage | 2026-02-23 | — |
| TASK-013 | iOS Bonjour browser + server picker UI | 2026-02-23 | — |
| TASK-014 | Tailscale manual address entry + persistence | 2026-02-23 | — |
| TASK-015 | iOS Settings screen | 2026-02-23 | — |
| TASK-016 | Tree list view (iOS) | 2026-02-23 | — |
| TASK-017 | Branch navigator view (iOS) | 2026-02-23 | — |
| TASK-018 | Message list view with markdown rendering | 2026-02-23 | — |
| TASK-019 | Real-time streaming view (60fps token rendering) | 2026-02-23 | — |
| TASK-020 | Tool execution status chips in conversation | 2026-02-23 | — |
| TASK-021 | Message input bar (multi-line + keyboard avoidance) | 2026-02-23 | — |
| TASK-022 | Send/stop behavior + optimistic UI | 2026-02-23 | — |
| TASK-023 | Draft persistence per branch | 2026-02-23 | — |
| TASK-024 | Server-side cancel_stream support | 2026-02-23 | — |
| TASK-025 | Token validation on WebSocket upgrade | 2026-02-23 | — |
| TASK-026 | Rate limiting for failed auth attempts | 2026-02-23 | — |
| TASK-027 | Token regeneration UI on macOS | 2026-02-23 | — |
| TASK-028 | Session persistence + last-viewed restore | 2026-02-23 | — |
| TASK-029 | BUG-06: Fix mobile client ↔ server protocol mismatch | 2026-02-24 | — |
| TASK-030 | BUG-08: Fix Bonjour service type mismatch | 2026-02-24 | — |
| TASK-031 | Add error type handler to WorldTreeStore — daemon errors silently dropped | 2026-02-23 | — |
| TASK-032 | Fix repeated macOS permission requests | 2026-02-24 | — |
| TASK-033 | Codebase audit — stability, memory, and efficiency pass | 2026-02-24 | — |
| TASK-034 | Investigate and optimize message pipeline latency | 2026-02-24 | — |
| TASK-035 | Implement conversation-level RAG: context scorer + search_conversation tool | 2026-02-24 | — |
| TASK-036 | UI/UX improvements — Lumen design review pass | 2026-02-24 | — |
| TASK-037 | Fourth audit pass: implement C-1 through L-5 fixes | 2026-02-24 | — |
| TASK-038 | Wire branch fork display: BranchLayoutView / addBranch disconnect | 2026-02-24 | — |
| TASK-039 | Wire SessionRotator into active streaming pipeline | 2026-02-24 | — |
| TASK-040 | Pass 5 audit fixes — C-1 through M-10 | 2026-02-24 | — |
| TASK-041 | Fix 3 UI bugs: project sort, sent message missing, input box height | 2026-02-25 | — |
| TASK-042 | Add paragraph formatting directive to CortanaIdentity system prompt | 2026-02-25 | — |
| TASK-043 | Remove CortanaConstants — rename to AppConstants throughout | 2026-02-25 | — |
| TASK-044 | Add sidebar sort picker (A-Z, Z-A, Newest, Oldest) | 2026-02-25 | — |
| TASK-045 | Fix sidebar sort button visibility and sort order | 2026-02-25 | — |
| TASK-046 | Fix auto-scroll: conversation view doesn't scroll to show new messages | 2026-02-25 | — |
| TASK-047 | Fix: scroll to bottom on conversation open + sort button invisible on macOS 15 | 2026-03-01 | Cortana |
| TASK-048 | Add search bar and sort picker to SimpleModeView sidebar | 2026-02-25 | — |
| TASK-049 | Fix conversation scroll content going behind input box | 2026-03-01 | Cortana (already fixed) |

---

## Quick Stats

| Status | Count |
|--------|-------|
| Blocked | 0 |
| In Progress | 0 |
| Ready for Review | 0 |
| Ready | 5 |
| Done | 49 |
| **Total** | **54** |

---

*Auto-generated by Ticketmaster*
