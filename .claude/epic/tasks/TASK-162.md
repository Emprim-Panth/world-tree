# TASK-162: MEDIUM — Legacy Identity Drift + Hard-Coded Coupling Cleanup

**Priority**: medium
**Status**: Pending
**Category**: architecture
**Epic**: Audit Follow-Up
**Sprint**: 4
**Agent**: spock
**Complexity**: M

## Description

Starfleet is the intended operator identity, but World Tree still carries live legacy coupling in both docs and code:

- `AnthropicAPIProvider` shells KB search with `~/Development/cortana-core` as its working directory
- `ImplementationViewModel` falls back to project name `cortana-core`
- active architecture and vision docs still describe the product as `Canvas`
- repo instructions still expose legacy team naming that no longer matches the operator contract

Some of this is cosmetic, some of it is behavioral. Both erode trust. Clean up the remaining legacy drift so the app’s identity and its runtime assumptions stop contradicting the user.

## Files to Modify

- **Modify**: `Sources/Core/Providers/AnthropicAPIProvider.swift`
- **Modify**: `Sources/Features/Implementation/ImplementationViewModel.swift`
- **Modify**: `Sources/Core/ProjectIntelligence/ProjectScanner.swift`
- **Modify**: `ARCHITECTURE.md`
- **Modify**: `docs/CANVAS-VISION.md`
- **Modify**: `CLAUDE.md`

## Requirements

- Remove hard-coded legacy repo paths where a neutral or configured path should be used
- Replace legacy product/team naming in active docs and operator-facing descriptions
- Keep compatibility comments only where they explain a real integration requirement
- Add one place in settings or docs that clearly states current canonical identity and legacy compatibility boundaries

## Acceptance Criteria

- [ ] No active runtime path depends on a hard-coded `cortana-core` checkout unless explicitly configured
- [ ] Implementation flows stop defaulting to the wrong project name
- [ ] Active architecture/docs reflect World Tree + Starfleet naming instead of Canvas-era language
- [ ] Remaining legacy references are clearly marked as compatibility notes, not current truth
- [ ] App behavior stays unchanged except for the removal of brittle legacy assumptions
