---
id: TASK-30
title: Build cortana-vision proof package assembler
status: done
priority: high
epic: EPIC-WT-AGENT-WORKSPACE
phase: 3
---

Create `src/vision/index.ts` in cortana-core. Implements `packageProof(sessionId)`: reads agent_screenshots for session, reads recording path, reads last 20 lines of build output from session state, reads agent's final summary message. Returns ProofPackage struct. Stores to `~/.cortana/proofs/{session_id}.json`.
