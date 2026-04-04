# TASK-129: Migration — game dev vaults → knowledge table, namespace=game-dev

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 4 — Knowledge Migration
**Agent:** Dax
**Depends on:** TASK-113, TASK-116, TASK-117
**Blocks:** TASK-131

## What

Migrate the game dev vault files into the knowledge table under the `game-dev` namespace. These are substantial reference documents — they need to be chunked into individual knowledge entries rather than inserted as single giant rows.

## Source Files

| File | Crew | Focus |
|------|------|-------|
| `~/.cortana/starfleet/crew/spock/GAME_DESIGN_VAULT.md` | spock | Game design strategy |
| `~/.cortana/starfleet/crew/spock/knowledge/game_director.md` | spock | Game direction |
| `~/.cortana/starfleet/crew/data/DND_ART_VAULT.md` | data | Art design reference |
| `~/.cortana/starfleet/crew/data/ENVIRONMENT_ART_VAULT.md` | data | Environment art |
| `~/.cortana/starfleet/crew/data/knowledge/art_director.md` | data | Art direction |
| `~/.cortana/starfleet/crew/geordi/UNREAL_TRANSITION_VAULT.md` | geordi | Game architecture |
| `~/.cortana/starfleet/crew/geordi/knowledge/game_architect.md` | geordi | Game architecture |
| `~/.cortana/starfleet/crew/uhura/knowledge/narrative_designer.md` | uhura | Narrative design |
| `~/.cortana/starfleet/crew/composer/MUSIC_VAULT.md` | composer | Music/audio |
| `~/.cortana/starfleet/crew/composer/knowledge/game_composer.md` | composer | Game music |
| `~/.cortana/starfleet/crew/worf/knowledge/game_qa_balance.md` | worf | Game QA |
| `~/.cortana/starfleet/crew/quark/knowledge/game_marketing.md` | quark | Game marketing |
| `~/.cortana/starfleet/crew/paris/knowledge/level_designer.md` | paris | Level design |
| `~/.cortana/starfleet/crew/scotty/knowledge/craft/game_developer.md` | scotty | Game development |

## Chunking Strategy

Large vault files (>2000 words) are chunked on `##` section headers. Each section becomes one knowledge row:
- title = section header
- body = section content (truncated to 4000 chars if needed)
- type = OBSERVATION (reference material) or PATTERN where applicable
- namespace = `game-dev` (fixed, no inference needed)
- crew_member = owning crew member

## Acceptance Criteria

- [ ] All 14 source files processed
- [ ] Large vaults chunked by `##` section (not inserted as single rows)
- [ ] namespace = 'game-dev' for all rows (no inference needed)
- [ ] crew_member correctly attributed per file
- [ ] Total rows: estimate 150-300 entries across all game dev vaults
- [ ] Source files NOT deleted by this script
- [ ] Dry-run mode available

## Files

- `cortana-core/bin/migrate-gamedev.ts` — new script
