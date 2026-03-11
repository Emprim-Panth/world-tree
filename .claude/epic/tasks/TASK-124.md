# TASK-124: Compass write integration

**Priority**: medium
**Status**: ready
**Category**: feature
**Source**: QA Audit Wave 4 — Feature Gap Analysis

## Description
Compass is currently read-only in World Tree (reads from compass.db). Add write capabilities so users can update project goals, phase, blockers, and log decisions directly from the Command Center.

## Acceptance Criteria
- [ ] Edit project goal from Compass project card
- [ ] Update project phase (exploring → building → testing → shipping)
- [ ] Add/remove blockers inline
- [ ] Log decisions with rationale
- [ ] Changes written to compass.db (compatible with cortana-core reads)
