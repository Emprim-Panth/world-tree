# TASK-111: GraphStore FNV-1a 64-bit hash collision potential

**Priority**: low
**Status**: done
**Category**: tech-debt
**Source**: QA Audit Wave 2

## Description
PenAssetStore uses FNV-1a 64-bit hashing for asset deduplication. While collision probability is low for typical usage, it's non-negligible at scale. No collision detection or fallback exists.

## Acceptance Criteria
- [x] Add collision detection (compare actual content on hash match)
- [ ] OR document the acceptable collision rate for current scale
- [x] Add test demonstrating collision handling
