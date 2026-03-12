# World Tree Stress Test Plan

**Source**: TASK-117 (QA Audit Wave 3)
**Created**: 2026-03-12

This document defines stress test scenarios for QA validation before shipping. Each scenario includes setup instructions, execution steps, expected behavior, pass/fail criteria, and performance baselines.

---

## 1. Database Stress

### 1.1 — 1000+ Branches in a Single Tree

**Setup**: Script or manual creation of a conversation tree with 1,000+ branches at varying depths (flat siblings + deep nesting).

**Steps**:
1. Open the tree in the sidebar
2. Expand all branch nodes
3. Scroll the full sidebar top-to-bottom
4. Click branches at random to switch

**Expected Behavior**: Sidebar renders without frame drops. Branch switching remains responsive.

**Pass/Fail Criteria**:
- Sidebar initial render: < 500ms
- Branch expand/collapse: < 100ms per node
- No dropped frames during scroll (60fps target)
- Memory delta from loading tree: < 50MB

---

### 1.2 — Conversation with 10,000+ Messages

**Setup**: Populate a single branch with 10,000+ messages (mixed user/assistant, varying lengths from 1 line to 2KB).

**Steps**:
1. Select the branch
2. Scroll to bottom of conversation
3. Scroll back to top
4. Jump to middle via search hit

**Expected Behavior**: Lazy loading keeps only visible messages in memory. Scroll is smooth.

**Pass/Fail Criteria**:
- Initial branch load: < 1s
- Scroll performance: 60fps with no hitches > 16ms
- Peak memory for message view: < 200MB
- Search-and-jump latency: < 500ms

---

### 1.3 — Concurrent Reads/Writes (World Tree + cortana-core)

**Setup**: World Tree open with an active conversation. cortana-core performing writes (hook events, session state updates) simultaneously.

**Steps**:
1. Start a conversation in a terminal (cortana-core writing to DB)
2. While streaming, browse other branches in the sidebar
3. Open Command Center (reads compass.db + conversations.db)
4. Trigger a search query

**Expected Behavior**: WAL mode allows concurrent readers. No SQLITE_BUSY errors surface to the user.

**Pass/Fail Criteria**:
- Zero user-visible "database locked" errors
- Read latency does not exceed 2x baseline under concurrent writes
- No data corruption (verify with `PRAGMA integrity_check` after test)

---

### 1.4 — WAL Checkpoint Under Heavy Write Load

**Setup**: Simulate sustained writes (100 messages/second) to grow the WAL file.

**Steps**:
1. Monitor WAL file size during sustained writes
2. Trigger a manual checkpoint (`PRAGMA wal_checkpoint(TRUNCATE)`)
3. Observe whether reads block during checkpoint

**Expected Behavior**: WAL file grows but checkpoints complete without blocking readers. WAL size stays bounded.

**Pass/Fail Criteria**:
- WAL file does not exceed 100MB before auto-checkpoint
- Checkpoint duration: < 2s
- Zero blocked reads during checkpoint
- Post-checkpoint WAL resets to near zero

---

### 1.5 — Migration on a Database with 100K+ Messages

**Setup**: Seed a database with 100K+ messages across multiple trees and branches.

**Steps**:
1. Trigger a schema migration (increment migration version)
2. Time the migration
3. Verify data integrity post-migration

**Expected Behavior**: Migration completes in a reasonable time without data loss.

**Pass/Fail Criteria**:
- Migration completes in < 30s for 100K messages
- Zero data loss (row counts match pre/post)
- App launches normally after migration
- `PRAGMA integrity_check` passes

---

## 2. Network Stress

### 2.1 — Gateway Disconnection During Active Dispatch

**Setup**: Active dispatch in progress through ark-gateway. Simulate network drop (kill gateway process or firewall port 4862).

**Steps**:
1. Start a dispatch from Command Center
2. Kill gateway mid-stream
3. Observe World Tree behavior
4. Restart gateway
5. Observe recovery

**Expected Behavior**: World Tree shows disconnection status. No crash. Reconnection happens automatically when gateway returns.

**Pass/Fail Criteria**:
- No crash or hang on disconnection
- UI shows clear disconnected state within 5s
- Auto-reconnection succeeds within 10s of gateway restart
- Dispatch status updates to failed/interrupted (not stuck in "running")

---

### 2.2 — WebSocket Rapid Connect/Disconnect Cycles

**Setup**: Script that connects and disconnects a WebSocket to the gateway 100 times in 10 seconds.

**Steps**:
1. Run rapid connect/disconnect script
2. Monitor gateway memory and file descriptor count
3. After script completes, verify a normal client can still connect

**Expected Behavior**: Gateway handles rapid cycles without resource leaks.

**Pass/Fail Criteria**:
- Gateway stays responsive throughout
- File descriptor count returns to baseline within 30s
- Memory does not grow beyond 20MB from baseline
- Normal client connects successfully after stress

---

### 2.3 — 50+ Concurrent WebSocket Subscribers

**Setup**: Script that opens 50 WebSocket connections subscribing to broadcast events.

**Steps**:
1. Open 50 concurrent WebSocket connections
2. Trigger a broadcast event (dispatch progress, heartbeat)
3. Verify all 50 receive the event
4. Measure broadcast latency

**Expected Behavior**: All subscribers receive events. Broadcast does not degrade linearly.

**Pass/Fail Criteria**:
- All 50 subscribers receive event
- Broadcast latency: < 500ms from first to last subscriber
- Gateway CPU spike: < 30% during broadcast
- No dropped connections

---

### 2.4 — Large Message Payloads (>100KB Tool Output)

**Setup**: Generate a tool output response exceeding 100KB (e.g., large file read, extensive search results).

**Steps**:
1. Trigger a tool call that produces >100KB output
2. Observe streaming behavior in the canvas
3. Verify message renders completely
4. Check memory after rendering

**Expected Behavior**: Message streams and renders without truncation. No OOM or UI freeze.

**Pass/Fail Criteria**:
- Full message renders without truncation
- Streaming does not stall for > 2s
- No UI freeze during render
- Memory for single large message: < 50MB overhead

---

## 3. UI Stress

### 3.1 — Rapid Branch Switching (20 in 2 Seconds)

**Setup**: Tree with 20+ branches, each with content.

**Steps**:
1. Click through 20 different branches as fast as possible (~100ms per click)
2. Observe final state

**Expected Behavior**: UI settles on the last-clicked branch. No stale content displayed. No crash.

**Pass/Fail Criteria**:
- Final displayed branch matches last click
- No mixed content from different branches
- No crash or hang
- Recovery to stable state: < 500ms after last click

---

### 3.2 — Typing While Streaming Response

**Setup**: Active streaming response in a conversation.

**Steps**:
1. Start a conversation that triggers a long streaming response
2. While streaming, click the input field and type continuously
3. Observe keystrokes and streaming

**Expected Behavior**: All keystrokes captured. Streaming continues uninterrupted.

**Pass/Fail Criteria**:
- Zero dropped keystrokes
- Input field responsive (< 50ms per keystroke)
- Stream does not stall due to typing
- No visual glitches in either input or stream

---

### 3.3 — 10+ Terminal Tabs Simultaneously

**Setup**: Open 10 or more terminal tabs across different projects.

**Steps**:
1. Open terminals one by one until 10+ are open
2. Switch between them
3. Run a command in each
4. Monitor memory

**Expected Behavior**: All terminals functional. Memory growth is linear, not exponential.

**Pass/Fail Criteria**:
- All 10 terminals accept input and display output
- Tab switching: < 200ms
- Memory per terminal: < 30MB
- Total app memory with 10 terminals: < 500MB
- No zombie processes on tab close

---

### 3.4 — Search While Database Under Write Load

**Setup**: cortana-core writing to the database while user performs searches.

**Steps**:
1. Start sustained writes via active conversation
2. Perform 10 search queries in rapid succession
3. Observe results and latency

**Expected Behavior**: Search returns correct results. Latency may increase slightly but remains usable.

**Pass/Fail Criteria**:
- Search results are correct (no missing hits from committed data)
- Search latency: < 1s per query under load (baseline < 200ms)
- No SQLITE_BUSY errors surfaced to user
- No UI freeze during search

---

### 3.5 — Fork from Branch While Stream Is Active

**Setup**: Active streaming response on a branch.

**Steps**:
1. Start a conversation that triggers a long response
2. While streaming, right-click a previous message and select Fork
3. Observe both the original stream and the new fork

**Expected Behavior**: Fork creates a new branch. Original stream either continues or is cleanly cancelled. No data corruption.

**Pass/Fail Criteria**:
- Fork succeeds and new branch is navigable
- Original branch messages are intact
- No duplicate or missing messages
- No crash
- Database integrity check passes

---

## 4. Memory Stress

### 4.1 — Long Session (4+ Hours)

**Setup**: Leave World Tree running with periodic interactions for 4+ hours.

**Steps**:
1. Record baseline memory at launch
2. Interact normally every 15-30 minutes (switch branches, search, open terminals)
3. Record memory at each interaction
4. After 4 hours, compare to baseline

**Expected Behavior**: Memory is stable or grows sub-linearly. No unbounded growth.

**Pass/Fail Criteria**:
- Memory growth over 4 hours: < 100MB above baseline
- No individual operation causes > 20MB permanent growth
- After closing all terminals and returning to idle: memory within 50MB of baseline
- No increase in system memory pressure warnings

---

### 4.2 — Open/Close 100 Branches

**Setup**: Tree with 100+ branches.

**Steps**:
1. Record baseline memory
2. Open each of 100 branches (loading messages), then switch to the next
3. After cycling through all 100, return to the first branch
4. Record memory

**Expected Behavior**: Previous branch content is released when switching. Memory does not accumulate per branch visited.

**Pass/Fail Criteria**:
- Peak memory during cycling: < 300MB
- Memory after completing cycle: within 30MB of baseline
- No stale view controllers or observers retained
- Instruments Leaks report: 0 leaks attributed to branch switching

---

### 4.3 — 1000 Search Operations

**Setup**: Database with substantial content (10K+ messages).

**Steps**:
1. Record baseline memory
2. Execute 1000 search queries programmatically (varied terms)
3. Record memory after every 100 queries
4. Final memory check after all 1000

**Expected Behavior**: Search result objects are released between queries. No accumulation.

**Pass/Fail Criteria**:
- Memory growth over 1000 searches: < 20MB
- No individual search leaks > 100KB
- Search latency does not degrade over time (query 1000 within 2x of query 1)
- Instruments Allocations: no monotonic growth in search-related classes

---

## Performance Baselines

These are the target baselines for a healthy system on a MacBook Pro (M-series, 16GB+ RAM):

| Metric | Baseline | Degraded | Failing |
|--------|----------|----------|---------|
| App launch to interactive | < 2s | 2-5s | > 5s |
| Branch switch | < 200ms | 200-500ms | > 500ms |
| Search query (idle DB) | < 200ms | 200-500ms | > 500ms |
| Search query (loaded DB) | < 1s | 1-2s | > 2s |
| Message render (single) | < 16ms | 16-33ms | > 33ms |
| Terminal tab open | < 500ms | 500ms-1s | > 1s |
| Idle memory | < 150MB | 150-300MB | > 300MB |
| Active memory (5 terminals) | < 350MB | 350-500MB | > 500MB |
| WebSocket reconnect | < 10s | 10-30s | > 30s |
| WAL checkpoint | < 2s | 2-5s | > 5s |

---

## Test Execution Notes

- Use Instruments (Allocations, Leaks, Time Profiler) for memory and performance measurements
- Use `PRAGMA integrity_check` before and after database stress tests
- Monitor with Activity Monitor for coarse memory/CPU tracking
- Log WAL file sizes with `ls -la` on the `-wal` file during database tests
- For network tests, `tcpkill` or firewall rules can simulate disconnection
- Automate repetitive scenarios (1000 searches, 100 branch opens) with XCTest or a helper script
