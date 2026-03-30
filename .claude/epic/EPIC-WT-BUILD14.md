# EPIC-WT-BUILD14: QA + SIMPLIFY + CORTANA-3 + LOCAL-INTELLIGENCE

**Status:** COMPLETE
**Date:** 2026-03-29
**Owner:** Evan + Cortana

---

## Problem Statement

World Tree Build 13 shipped the Local Intelligence layer but left behind significant technical debt: broken git repository, non-compiling test suite, 35+ silent error swallowing violations, orphaned chat-era code, no design system, and three incomplete epics (SIMPLIFY, CORTANA-3, LOCAL-INTELLIGENCE) with zero implementation.

## Goals

1. Fix all infrastructure issues (git, tests, code quality)
2. Complete SIMPLIFY — remove chat-era dead code
3. Implement CORTANA-3 — autonomy panels, scheduled agents, knowledge pipeline
4. Implement LOCAL-INTELLIGENCE — inference routing, offline mode, health monitoring
5. Ship as a single tested, verified build

## What Was Built

### Phase 1: QA & Infrastructure
| Item | Before | After |
|------|--------|-------|
| Git repository | Broken (.git/objects missing) | Repaired from remote |
| Test suite | 22 orphaned dirs, won't compile | 77 tests, 0 failures |
| `try?` on DB/network calls | ~35 violations | 0 (proper do/catch + wtLog) |
| `unsafeReentrantRead/Write` | 8 instances in BrainIndexer | Replaced with async read/write |
| Empty catch blocks | 2 (silent observation death) | Fixed with CancellationError handling |

### Phase 2: SIMPLIFY
| Item | Detail |
|------|--------|
| Mobile app | Deleted (iOS, Watch, Widget, Share — 60 files, archived) |
| Dead constants | 30+ unused UserDefaults keys removed from Constants.swift |
| Dead utilities | OneShotGuard, resolveWorkingDirectory, extractHTTPContentLength removed |
| Palette design tokens | Created `enum Palette` with semantic colors, replaced 15+ hardcoded references |
| CLAUDE.md | Rewritten for current command center architecture |

### Phase 3: CORTANA-3
| Item | Detail |
|------|--------|
| DB migrations v36-v38 | `cortana_alerts`, `starfleet_activity`, `hook_events` tables |
| BriefingStore | Reads daily briefings from ~/.cortana/briefings/ + alerts from DB |
| SystemHealthStore | Async health checks: Ollama, ContextServer, Compass DB, Brain Index |
| BriefingAlertsView | Unified panel: alerts with resolve, briefing display, system health |
| StarfleetStore | Crew roster with DB-backed activity tracking |
| StarfleetCommandView | Navigation panel: crew grid cards + activity timeline |
| Scheduled agents | Morning Brief (daily 6am ET), Drift Detector (every 6h) |
| briefing-inject.sh | SessionStart hook: slop counteractions + proactive triggers |
| knowledge-promote.sh | Candidate → validated → promoted lifecycle, auto-promote at 3 occurrences |

### Phase 4: LOCAL-INTELLIGENCE
| Item | Detail |
|------|--------|
| QualityRouter.routeAndExecute() | Full pipeline: route → infer → measure latency → assess confidence → escalate → log |
| Confidence assessment | Response length, hedging language, refusal pattern detection |
| Offline mode | Health polling (60s), fallback routing when Ollama offline, BrainIndexer skip |
| Ollama KeepAlive | 24h model retention via OLLAMA_KEEP_ALIVE env in launchd plist |
| ContextServer endpoints | POST /inference/log, GET /inference/recent |
| Intelligence Dashboard | Escalation stats, offline indicator, Palette tokens |

## Metrics

| Metric | Start | End |
|--------|-------|-----|
| Source files | ~130 | 47 |
| Source LOC | ~18,800 | 9,400 |
| Test files | ~46 (broken) | 6 (77 tests passing) |
| Navigation panels | 6 | 8 |
| DB tables | 7 | 10 |
| ContextServer routes | 6 | 10 |
| Scheduled agents | 0 | 2 |
| Design tokens | 0 | Palette system |

## Verification

- [x] `xcodebuild build` — BUILD SUCCEEDED
- [x] `xcodebuild test` — 77 tests, 0 failures
- [x] ContextServer /intelligence/status — responding
- [x] ContextServer /brain/search — returning results (89 chunks indexed)
- [x] ContextServer /agent/active — responding
- [x] ContextServer /inference/log POST — logging to DB
- [x] ContextServer /inference/recent GET — retrieving entries
- [x] Ollama — 4 models available (72B, 32B, coder, embed)
- [x] World Tree — running (PID verified)
- [x] Scheduled agents — Morning Brief + Drift Detector created and enabled
- [x] Knowledge promotion — add/increment/auto-promote verified
- [x] briefing-inject.sh — slop counteractions rendering correctly

## Commits

1. `b8eadf4` — Build 13 (Local Intelligence layer)
2. `e23d482` — Test cleanup (22 dirs removed, 77 passing)
3. `d240181` — try? + unsafeReentrant fixes
4. `cfad3d9` — CLAUDE.md rewrite
5. `8e1ea88` — Mobile removal, dead code, Palette
6. `06b2701` — CORTANA-3 panels (Briefing/Alerts, Health, Starfleet)
7. `3b89561` — Scheduled agent output directories
8. `1763200` — LOCAL-INTELLIGENCE routing pipeline + endpoints
9. TBD — Offline mode, KeepAlive, consolidated epic

## Decision Log

- **Mobile archived**: No value without conversation UI — dashboard for a dashboard
- **Health Monitor agent skipped**: Plan limit (1 hourly session) + local SystemHealthStore already covers this better since remote agents can't check local services
- **`unsafeReentrantRead` kept for `refreshCount()`**: Only sync caller in BrainIndexer init/defer — all async paths use proper `await read/write`
- **Offline routing**: Non-critical local tasks skip (don't waste Claude tokens), important tasks escalate to Claude
