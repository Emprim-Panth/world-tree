# TASK-117: Seed crew_registry — all crew members, tiers, namespace access

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 1 — DB Foundation
**Agent:** Scotty
**Depends on:** TASK-113, TASK-116
**Blocks:** TASK-118, TASK-119, TASK-120

## What

Populate `crew_registry` with every crew member from the Constitution. This is the harness's authority for who can do what. The harness reads this at session spawn — it cannot be overridden by an agent.

## Crew to Seed (from Constitution §III–IV)

**Tier 1 — CTO**
| name | tier | role_title | namespaces_read | namespaces_write | can_spawn_tiers |
|------|------|-----------|-----------------|-----------------|----------------|
| cortana | 1 | CTO | ["*"] | ["*"] | [2,3,4] |

**Tier 2 — Department Head**
| picard | 2 | Mission Lead | ["*"] | ["*"] | [3,4] |

**Tier 3 — Leads**
| spock | 3 | Strategist | ["*"] | ["*"] | [4] |
| geordi | 3 | Architect | project-scoped + project-development + game-dev | same | [4] |
| data | 3 | Designer | project-scoped + project-development + game-dev | same | [4] |
| worf | 3 | QA Lead | project-scoped + game-dev | same | [4] |
| torres | 3 | Performance Lead | project-scoped | same | [4] |
| dax | 3 | Integration Lead | project-scoped | same | [4] |
| scotty | 3 | Build/DevOps | project-scoped + cortana-system | same | [4] |
| uhura | 3 | Copy/Docs | project-scoped + game-dev | same | [4] |
| troi | 3 | UX Research | project-scoped | project-development + game-dev | [4] |
| seven | 3 | Competitive Intel | project-scoped | job-acquisition + project-development | [4] |
| bashir | 3 | Debugging Lead | project-scoped | same | [4] |
| garak | 3 | Adversarial QA | project-scoped | [] (read-only) | [] |
| q | 3 | Research | ["*"] | ["review-queue"] | [] |
| kim | 3 | Documentation Lead | project-scoped | same | [4] |
| quark | 3 | Marketing | project-scoped | job-acquisition + forge-and-code + game-dev | [4] |
| composer | 3 | Music/Audio Lead | game-dev | game-dev | [4] |

**Tier 4 — Workers** (haiku, no spawn)
| obrien, paris, nog, sato, odo, zimmerman | 4 | Worker | project-scoped | project-scoped | [] |

## Acceptance Criteria

- [ ] All crew members seeded with INSERT OR IGNORE in v42 migration
- [ ] `profile_path` set to actual `~/.cortana/starfleet/crew/{name}/CLAUDE.md` for each
- [ ] Tier integers correct (1=CTO, 2=dept head, 3=lead, 4=worker)
- [ ] namespaces_read/write stored as valid JSON arrays
- [ ] MigrationManagerTests verifies row count >= 24 after migration
- [ ] Cortana (tier 1) has namespaces_read=`["*"]`, namespaces_write=`["*"]`

## Note on "project-scoped"

Leads don't have a fixed namespace_write list — it's determined at spawn time based on the project they're assigned to. The registry stores `["assigned_project"]` as a sentinel. The harness resolves it to the actual namespace when spawning.
