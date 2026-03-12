# TASK-122: Auto-decision logging in memory system

**Priority**: medium
**Status**: done
**Category**: feature
**Source**: QA Audit Wave 4 — Feature Gap Analysis

## Description
Architectural decisions made during conversations should be automatically detected and logged to the memory system. Currently decisions are only captured if manually logged.

## Acceptance Criteria
- [x] Detect decision patterns in conversation messages
- [x] Auto-log decisions with context and rationale
- [x] Decisions appear in Compass knowledge base
- [x] User can review and approve/reject auto-logged decisions

## Implementation (2026-03-12)

**New files:**
- `Sources/Core/Context/DecisionDetector.swift` — Pattern-based detection of decision language in assistant messages. Scans paragraphs for 30+ signal phrases ("I decided to", "going with", "the approach will be", etc.) with weighted confidence scoring. Extracts decision summary + rationale. Deduplicates via Jaccard similarity.
- `Sources/Core/Database/AutoDecisionStore.swift` — SQLite-backed review queue (`canvas_auto_decisions` table). Lifecycle: pending -> approved/rejected. Approved decisions are logged to gateway memory as `[DECISION]` entries via `GatewayClient.logMemory()`. Rejected decisions kept 30 days to prevent re-detection.
- `Sources/Features/CommandCenter/DecisionReviewSection.swift` — SwiftUI review UI in the Command Center. Shows pending decisions with approve/reject buttons, confidence badges, project tags, expand for rationale. Bulk approve/dismiss all.

**Modified files:**
- `Sources/Core/Database/MigrationManager.swift` — Added migration v23 for `canvas_auto_decisions` table.
- `Sources/Features/Document/DocumentEditorView.swift` — Hooked `DecisionDetector` into post-stream-completion flow. After assistant response is persisted, detection runs and novel decisions are saved as pending.
- `Sources/Features/CommandCenter/CommandCenterView.swift` — Added `DecisionReviewSection` to Command Center layout.
