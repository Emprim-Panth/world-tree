# TASK-116: Seed namespaces table — 11 canonical entries

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 1 — DB Foundation
**Agent:** Scotty
**Depends on:** TASK-113
**Blocks:** TASK-117, TASK-119

## What

Populate the `namespaces` table with the 11 pre-defined entries from the Constitution. These are immutable — no agent can add to them. The seed runs inside the v42 migration so they exist from first boot.

## Namespaces to Seed

| id | label | description |
|----|-------|-------------|
| `world-tree` | World Tree | WorldTree app — features, harness, sessions, bridge, UI |
| `bim-manager` | BIM Manager | Plant 3D admin, BOM, user management |
| `archon-cad` | Archon-CAD | Rust CAD engine, egui, commands, file I/O |
| `forge-toolbox` | ForgeToolbox | Calculator engine, iOS persistence |
| `doc-forge` | DocForge | .NET MAUI document generation |
| `game-dev` | Game Dev | All game development — design, art, audio, levels, narrative, balance |
| `cortana-system` | Cortana System | Harness, daemon, hooks, MCP, brain infrastructure |
| `project-development` | Project Development | General engineering — patterns, architecture, code quality, testing |
| `job-acquisition` | Job Acquisition | Business — clients, revenue, proposals, positioning, pricing |
| `forge-and-code` | Forge & Code | Company — brand, strategy, partnerships, public presence |
| `review-queue` | Review Queue | Unclassified — awaits Evan's routing in WorldTree |

## Acceptance Criteria

- [ ] All 11 rows inserted as part of v42 migration (INSERT OR IGNORE)
- [ ] Verified via MigrationManagerTests — namespace count == 11 after migration
- [ ] No application code inserts into `namespaces` (enforced via code review, no INSERT outside migration)

## Implementation Note

Use `INSERT OR IGNORE` so re-running migrations on existing DBs is safe.
