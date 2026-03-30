# EPIC-WT-LOCAL: World Tree Local Intelligence — M4 Max 128GB Strategy

**Status:** COMPLETE
**Priority:** Critical
**Owner:** Evan
**Created:** 2026-03-29
**Tasks:** TASK-41 through TASK-55
**Hardware:** Mac Studio M4 Max — 16 CPU, 40 GPU, 128 GB unified, 1.7 TB free

---

## PRD — Product Requirements Document

### Problem Statement

Cortana today runs on one axis: Claude API. Every session, every agent dispatch, every scout query, every scheduled briefing — it all either burns Anthropic tokens or uses a dramatically underpowered local model (qwen2.5-coder:7b for Scout, nothing else). This creates three problems:

1. **Cost ceiling.** Claude is the right tool for hard reasoning, architecture, and complex code. It is the wrong tool for ticket scanning, commit summarization, test triage, log analysis, and the 80% of work that doesn't need frontier intelligence. Every Sonnet call to "check if tests pass" is $0.01+ that could be $0.00 locally.

2. **Availability ceiling.** Claude requires internet. Rate limits exist. When Evan's working at 2 AM on a creative streak, a rate limit kills momentum. Local models don't rate-limit. They don't go down. They don't require connectivity.

3. **Wasted hardware.** The M4 Max with 128 GB unified memory is one of the strongest local inference machines available. It's currently running a single 32B model that uses 15% of available RAM. The 40-core GPU and Neural Engine sit idle. This machine could run a 70B reasoning model, a 32B code model, and an embedding model *simultaneously* with room to spare.

The gap isn't "replace Claude" — it's "stop sending Claude work that a local 70B can handle." Claude is the surgeon. Local models are the triage nurses, the lab techs, the record keepers. World Tree is the hospital that routes patients to the right provider.

### Goals

1. **Intelligent workload routing** — World Tree and Cortana's infrastructure automatically route tasks to the cheapest capable provider: local 70B for reasoning/summarization, local 32B for code understanding, Claude Sonnet for complex code, Claude Opus for novel architecture — based on task complexity, not habit
2. **24/7 autonomous capability** — Scheduled agents (morning brief, drift detection, health checks) run entirely on local models with zero API cost, escalating to Claude only when they find something that requires frontier reasoning
3. **Sub-second local queries** — Scout, brain search, commit summarization, and ticket analysis all run on local models fast enough that they feel instantaneous on this hardware
4. **Semantic brain search** — The entire brain (~/.cortana/brain/) and knowledge base is embedded and searchable by meaning, not just keywords — powered by a local embedding model running continuously
5. **Quality gates** — Every local model result that influences a decision has a confidence signal. Below threshold, it escalates to Claude automatically. No silent quality degradation.

### Non-Goals

| Feature | Reason Not In Scope | Alternative |
|---------|---------------------|-------------|
| Replace Claude for complex code generation | Local models can't match Claude on novel architecture or multi-file refactors | Claude remains primary for hard work |
| Fine-tune models on Evan's codebase | Prohibitive compute time, marginal gain over good prompting | Use retrieval-augmented generation with local embeddings |
| Run models larger than 70B | Q4 quantized 70B fits comfortably; 120B+ would consume too much memory and limit concurrency | 70B is the sweet spot for quality/throughput |
| Build a custom model serving layer | Ollama already handles this well | Extend Ollama config, don't replace it |
| Voice/multimodal local processing | Not revenue-accelerating | Use Claude's built-in capabilities when needed |

### Success Metrics

| Metric | Before | Target |
|--------|--------|--------|
| Claude API calls per day (non-interactive) | ~100% of automated work | <20% (only escalations) |
| Cost of scheduled agents (morning brief + drift + health) | ~$2-5/day on Sonnet | $0/day (100% local) |
| Scout response time | 3-5s (qwen2.5-coder:7b on old machine) | <1s (qwen2.5-coder:32b on M4 Max) |
| Brain search capability | FTS5 keyword only | Semantic similarity + FTS5 hybrid |
| Models loaded simultaneously | 1 (32B) | 3 (70B reasoning + 32B code + embedding) |
| GPU memory utilization | ~15% | ~70-80% |
| Offline capability | Zero (everything needs API) | Full autonomous operation (scheduled agents, search, summarization) |

### User Stories

1. As **Evan**, when I open World Tree in the morning, the briefing was prepared overnight by a local 70B model at zero cost — and it's good enough that I don't need to re-run it on Claude.

2. As **a Claude session**, when I need to understand a file before editing it, Scout uses the local 32B coder and returns a compressed summary in <1 second — preserving my context window without waiting or spending API tokens.

3. As **Evan**, when I search the brain for "that time we had a signing certificate issue," the system finds it by meaning — not just keyword match — because a local embedding model has indexed everything.

4. As **the drift detector**, when I find uncommitted work in BIM Manager that's been sitting for 36 hours, I write the alert locally. Only if I detect something that needs frontier reasoning (conflicting architecture decisions, ambiguous scope) do I escalate to Claude.

5. As **Evan**, I can work at 2 AM with no internet and still have full Scout, brain search, commit analysis, and ticket scanning — everything except interactive Claude sessions runs locally.

---

## FRD — Functional Requirements Document

### Architecture: Before → After

**Before:**
```
┌─────────────────────────────────────────┐
│              Claude API                 │
│  (100% of automated + interactive work) │
└──────────────────┬──────────────────────┘
                   │
         ┌─────────┴──────────┐
         │   Scout (7b model)  │  ← dramatically underpowered
         └────────────────────┘

Ollama: qwen2.5-coder:32b (loaded but only used by Scout config)
GPU: 15% utilized
RAM: 19 GB of 128 GB used
Neural Engine: idle
```

**After:**
```
┌─────────────────────────────────────────┐
│              Claude API                 │
│     (complex code, architecture,        │
│      novel reasoning, interactive)      │
└──────────────────┬──────────────────────┘
                   │ escalation only
         ┌─────────┴──────────┐
         │   Quality Router    │  ← decides local vs cloud
         └────┬────────┬───────┘
              │        │
    ┌─────────┴──┐  ┌──┴──────────┐  ┌──────────────┐
    │  Reasoning  │  │  Code Intel  │  │  Embeddings   │
    │  qwen2.5:72b  │  │  qwen2.5-   │  │  nomic-embed  │
    │  (42 GB)    │  │  coder:32b   │  │  -text (274MB)│
    │             │  │  (19 GB)     │  │               │
    │ Briefings   │  │ Scout        │  │ Brain search  │
    │ Drift check │  │ File summary │  │ Knowledge     │
    │ Triage      │  │ Code search  │  │ Correction    │
    │ Summarize   │  │ Diff explain │  │ matching      │
    └─────────────┘  └─────────────┘  └───────────────┘

Total VRAM: ~69 GB of 128 GB  (54% — room for growth)
Concurrent inference: all 3 models loaded simultaneously
Offline capable: everything except Claude escalation
```

### Deletion Manifest

| File / Module | Lines | Delete Reason |
|---------------|-------|---------------|
| None | 0 | This epic is purely additive — new capability, no removals |

### Feature Specifications

#### F1: Model Fleet — Download and Configure

**Purpose:** Install the right models for each workload tier. The 128 GB unified memory strategy is: 70B reasoning + 32B code + embedding model, all loaded concurrently, using ~62 GB total (48% of available RAM).

**Model Fleet:**

| Model | Size (disk) | Size (RAM) | Purpose | Speed (est.) |
|-------|------------|------------|---------|-------------|
| `qwen2.5:72b` | ~47 GB | ~49 GB | Reasoning, summarization, briefings, triage, drift analysis | ~20-30 tok/s |
| `qwen2.5-coder:32b` | 19 GB | ~20 GB | Code understanding, Scout queries, diff explanation | ~40-50 tok/s |
| `nomic-embed-text` | 274 MB | ~300 MB | Embedding for semantic search over brain + knowledge | ~1000 doc/s |

**Why these models:**
- `qwen2.5:72b` — Best open-weight general model at this size. Strong reasoning, summarization, and analysis. Fits comfortably in 128 GB alongside other models. (qwen3 not yet on Ollama registry.)
- `qwen2.5-coder:32b` — Already installed. Excellent code understanding. The right tool for Scout.
- `nomic-embed-text` — 768-dim embeddings, 8192 token context. Tiny footprint. Best quality/size ratio for local embedding.

**Ollama Configuration:**
```bash
# ~/.cortana/ollama-config.sh (run on boot via launchd)
export OLLAMA_NUM_PARALLEL=4          # 4 concurrent requests
export OLLAMA_MAX_LOADED_MODELS=3     # keep all 3 in memory
export OLLAMA_KEEP_ALIVE="24h"        # don't unload between requests
export OLLAMA_FLASH_ATTENTION=1       # M4 Max optimized attention
```

**Constraints:**
- All models use Q4_K_M quantization (best quality/speed tradeoff for Apple Silicon)
- Total memory budget: 65 GB max (leaves 63 GB for macOS, Xcode, World Tree, browsers)
- If memory pressure detected, embedding model unloads first (smallest, cheapest to reload)

#### F2: Quality Router — Task Classification and Routing

**Purpose:** A lightweight decision layer that examines each task and routes it to the cheapest provider that can handle it at acceptable quality. Not a complex ML classifier — a rule-based router with confidence thresholds.

**Routing Rules:**

| Task Type | Primary | Escalation Trigger | Escalation Target |
|-----------|---------|-------------------|-------------------|
| File summarization | Local 32B (Scout) | Never — summaries are advisory | — |
| Commit/diff explanation | Local 32B | Diff touches >10 files or >500 lines | Claude Sonnet |
| Ticket scanning/parsing | Local 72B | Never — structured data extraction | — |
| Morning briefing | Local 72B | Finds conflicting priorities or ambiguous blockers | Claude Sonnet (one-shot) |
| Drift detection | Local 72B | Detects potential architecture violation | Claude Sonnet |
| Health monitoring | Local 72B | Never — binary checks | — |
| Brain/knowledge search | Local embeddings + 72B | Query returns low-confidence results (<0.7 similarity) | Claude Sonnet |
| Code generation | Claude Sonnet | Complex multi-file or novel algorithm | Claude Opus |
| Architecture decisions | Claude Opus | Never routes down | — |
| Interactive conversation | Claude Sonnet/Opus | Per existing model escalation rules | — |

**Interface:**
```swift
// Sources/Core/Intelligence/QualityRouter.swift
enum InferenceProvider {
    case local72B      // qwen2.5:72b — reasoning, summarization
    case local32B      // qwen2.5-coder:32b — code understanding
    case localEmbed    // nomic-embed-text — embeddings
    case claudeSonnet  // complex code, escalated tasks
    case claudeOpus   // architecture, novel reasoning
}

enum TaskComplexity {
    case routine    // → local
    case moderate   // → local, escalate on low confidence
    case complex    // → Claude Sonnet
    case frontier   // → Claude Opus
}

struct QualityRouter {
    static func route(_ task: InferenceTask) -> InferenceProvider
    static func shouldEscalate(_ result: InferenceResult) -> Bool
}
```

**Confidence Signal:**
Every local model result includes a self-assessed confidence:
- The 72B model is prompted to include `[confidence: high/medium/low]` in structured outputs
- Results tagged `low` are automatically flagged for escalation
- World Tree UI shows confidence badges on locally-generated content

**Constraints:**
- Router logic must be <100 lines — complexity here defeats the purpose
- No ML classifier for routing (that's scope creep) — use task-type matching
- Escalation must be transparent: "Escalating to Claude because [reason]"
- Never escalate health checks or file summaries (waste of API tokens)

#### F3: Scout Upgrade — 32B + Concurrent Queries

**Purpose:** Upgrade Scout from 7b to 32b model (already loaded), and enable concurrent Scout queries. On the M4 Max, Scout should return compressed file summaries in <1 second.

**Changes:**
1. Update Scout config to use `qwen2.5-coder:32b` (already done in MCP settings — verify working)
2. Enable parallel Scout queries (OLLAMA_NUM_PARALLEL=4)
3. Add `scout_batch` command for multi-file understanding in a single call
4. Update `scout_understand` to use 32B quality for deeper analysis

**Interface:**
```
scout_batch project files[] question
  → Reads all files, returns single compressed answer
  → Uses qwen2.5-coder:32b
  → Parallelizes file reading, single inference call for answer
```

**Performance Targets:**
| Operation | Before (7b, old machine) | Target (32b, M4 Max) |
|-----------|-------------------------|---------------------|
| scout_summarize (single file) | 3-5s | <1s |
| scout_understand (3 files) | 8-12s | <2s |
| scout_find (codebase search) | 5-10s | <2s |
| scout_map (project structure) | 3-5s | <1s |

**Constraints:**
- 32B model must stay loaded (OLLAMA_KEEP_ALIVE=24h) — no cold-start penalty
- Scout queries never escalate to Claude — they're advisory, not decision-making
- Batch queries capped at 10 files (prevent context overflow)

#### F4: Semantic Brain Search — Local Embeddings

**Purpose:** Index the entire brain, knowledge base, corrections, patterns, and project notes with local embeddings. Enable "search by meaning" — find relevant corrections even when the keywords don't match.

**Architecture:**
```
~/.cortana/brain/**/*.md
  → Chunked (512 tokens per chunk, 128 token overlap)
    → Embedded via nomic-embed-text (local, zero cost)
      → Stored in SQLite FTS5 + vector table
        → Queried via hybrid search (FTS5 keyword + cosine similarity)
          → Results ranked by combined score
```

**Implementation:**

1. **Indexer** — Runs on boot + watches brain directory for changes
   - Chunks markdown files into ~512-token segments
   - Generates 768-dim embeddings via Ollama API
   - Stores in `~/.cortana/brain-index.db`:
     ```sql
     CREATE TABLE brain_chunks (
         id INTEGER PRIMARY KEY,
         file_path TEXT NOT NULL,
         chunk_index INTEGER NOT NULL,
         content TEXT NOT NULL,
         embedding BLOB NOT NULL,  -- 768 float32s = 3072 bytes
         updated_at TEXT DEFAULT (datetime('now')),
         UNIQUE(file_path, chunk_index)
     );
     CREATE VIRTUAL TABLE brain_fts USING fts5(content, file_path);
     ```

2. **Search API** — Hybrid keyword + semantic
   ```
   GET /brain/search?q={natural language query}&limit={n}
     Response: {
       results: [{
         file: string,
         chunk: string,
         score: float,       // 0-1 combined score
         match_type: "semantic" | "keyword" | "hybrid"
       }]
     }
   ```

3. **MCP Integration** — New `brain_search` tool available in all Claude sessions
   ```
   brain_search query limit
     → Hybrid search over entire brain
     → Returns top-N chunks with file path and relevance score
     → Zero API cost (local embeddings)
   ```

**Index Size Estimate:**
- Brain directory: ~50 markdown files, ~200KB total
- Chunks: ~400 chunks × 3KB each (content + embedding) = ~1.2 MB
- Negligible storage and memory footprint

**Constraints:**
- Re-index on file change (DispatchSource watcher), not on timer
- Embedding dimension: 768 (nomic-embed-text native)
- Cosine similarity threshold for results: 0.6 minimum
- Hybrid scoring: `0.4 * fts5_rank + 0.6 * cosine_similarity`
- Index lives in separate DB file (not conversations.db — different lifecycle)

#### F5: Local Autonomous Agents — Zero-Cost Scheduled Work

**Purpose:** The scheduled agents from EPIC-CORTANA-3 (morning brief, drift detector, health monitor) should run entirely on local models by default. Claude is only called when the local model flags something it can't handle.

**Agent Routing:**

| Agent | Primary Model | Escalation |
|-------|--------------|------------|
| Morning Brief | qwen2.5:72b | If conflicting blockers or ambiguous priority → one Claude Sonnet call to resolve |
| Drift Detector | qwen2.5:72b | If potential architecture violation → Claude Sonnet assessment |
| Health Monitor | qwen2.5:72b | Never — binary health checks |
| Ticket Scanner | qwen2.5:72b | Never — structured extraction |
| Commit Summarizer | qwen2.5-coder:32b | If merge commit touches >20 files → Claude Sonnet |

**How it works:**
1. Scheduled agent starts (RemoteTrigger or launchd)
2. Agent runs with `--model qwen2.5:72b` (or equivalent Ollama endpoint)
3. Uses Scout (32B) for code reading, brain search for knowledge
4. Generates output (briefing, alert, health report)
5. Self-assesses confidence on any findings
6. Low-confidence items: makes one targeted Claude API call for that specific finding
7. Writes final output to filesystem (briefings/, alerts/, health/)
8. WorldTree picks up via file watcher

**Cost Model:**
| Scenario | Before (all Claude) | After (local + escalation) |
|----------|--------------------|-----------------------------|
| Morning brief (daily) | ~$0.50-1.00 | $0.00 (local) + ~$0.05 avg escalation |
| Drift check (4x daily) | ~$0.40-0.80 | $0.00 (local) + ~$0.02 avg escalation |
| Health check (12x daily) | ~$0.24-0.48 | $0.00 (always local) |
| **Monthly total** | **$35-70** | **$2-5** (escalations only) |

**Constraints:**
- Local agents must complete within 5 minutes (timeout)
- Escalation budget: max 3 Claude calls per agent run
- If Ollama is down, skip the run and log a health alert (don't fall back to full Claude)
- Agent output quality must be reviewed by Evan for first 2 weeks before trusting fully

#### F6: World Tree Intelligence Dashboard

**Purpose:** Surface local model status, routing decisions, cost savings, and model health in World Tree's Command Center.

**UI Spec:**
```
System Intelligence (new section in Command Center, below project grid)
├── Model Status
│   ├── qwen2.5:72b — loaded / idle / active (X tok/s)
│   ├── qwen2.5-coder:32b — loaded / idle / active (X tok/s)
│   ├── nomic-embed-text — loaded / idle / active
│   └── Memory: 62 GB / 128 GB used
├── Today's Routing
│   ├── Local: 847 queries (94%)
│   ├── Claude Sonnet: 48 queries (5%)
│   ├── Claude Opus: 3 queries (1%)
│   └── Est. savings: $4.20 vs all-Claude
├── Brain Index
│   ├── 412 chunks indexed
│   ├── Last reindex: 3 min ago
│   └── Search: [query field]
└── Recent Escalations
    ├── "Drift: BIM Manager architecture question" → Sonnet (12:34 PM)
    └── "Brief: conflicting priorities ForgeSchedule vs DocForge" → Sonnet (6:02 AM)
```

**Data source:** Routing decisions logged to `inference_log` table:
```sql
CREATE TABLE inference_log (
    id INTEGER PRIMARY KEY,
    task_type TEXT NOT NULL,
    provider TEXT NOT NULL,     -- 'local_72b', 'local_32b', 'embed', 'sonnet', 'opus'
    input_tokens INTEGER,
    output_tokens INTEGER,
    latency_ms INTEGER,
    confidence TEXT,            -- 'high', 'medium', 'low'
    escalated INTEGER DEFAULT 0,
    escalation_reason TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);
```

**Constraints:**
- Log table auto-prunes entries older than 30 days
- Stats computed from SQLite aggregates, not in-memory (cheap)
- Model status polled from Ollama API (`/api/ps`) every 30 seconds
- Dashboard visible only in Command Center (not a separate nav panel — avoid clutter)

#### F7: Offline Mode

**Purpose:** When internet is unavailable, Cortana's infrastructure continues operating on local models. Claude sessions can't start, but everything else works.

**What works offline:**
- Scout (all operations)
- Brain search (semantic + keyword)
- Scheduled agents (local model, skip escalation)
- World Tree (all features)
- Ticket scanning
- Commit analysis
- File summarization

**What doesn't work offline:**
- Interactive Claude sessions
- Escalation calls
- RemoteTrigger (requires Anthropic servers)

**Detection:**
- Health monitor checks `api.anthropic.com` reachability
- If unreachable: sets `offline_mode = true` in health status
- Agents suppress escalation (log "would have escalated: [reason]" instead)
- World Tree shows "Offline — Local models active" banner

**Constraints:**
- No degraded-quality output presented as if it were Claude-quality
- Offline badge must be visible whenever active
- Escalation queue: items that would have escalated are queued and sent when connectivity returns

### API Contracts

```
# Ollama API (already exists, document for reference)
POST http://localhost:11434/api/generate
  Request: { model: string, prompt: string, stream: bool }
  Response: { response: string, done: bool }

POST http://localhost:11434/api/embed
  Request: { model: "nomic-embed-text", input: string }
  Response: { embeddings: float[][] }

GET http://localhost:11434/api/ps
  Response: { models: [{ name, size, processor, expires_at }] }

# World Tree ContextServer extensions (port 4863)
GET /brain/search?q={query}&limit={n}
  Response: { results: [{ file, chunk, score, match_type }] }
  Auth: none (localhost only)
  Errors: 503 (embedding model not loaded)

GET /intelligence/status
  Response: { models: ModelStatus[], routing_today: RoutingStats, brain_index: IndexStats }
  Auth: none (localhost only)

GET /intelligence/log?limit={n}
  Response: { entries: InferenceLogEntry[] }
  Auth: none (localhost only)
```

### Data Model

**Add:**
| Table | Schema | Purpose |
|-------|--------|---------|
| `inference_log` | id, task_type, provider, input_tokens, output_tokens, latency_ms, confidence, escalated, escalation_reason, created_at | Track all inference routing decisions |
| `brain_chunks` (separate DB) | id, file_path, chunk_index, content, embedding BLOB, updated_at | Semantic search index over brain |
| `brain_fts` (separate DB) | FTS5 virtual table on brain_chunks.content | Keyword search component |

**Modify:**
| Table | Change | Reason |
|-------|--------|--------|
| None | — | All changes are additive |

**Remove:**
| Table | Removal Strategy |
|-------|-----------------|
| None | — |

**Migration sequence:**
1. Add `inference_log` table to conversations.db (v35)
2. Create `~/.cortana/brain-index.db` with brain_chunks + brain_fts (separate DB, managed by indexer)

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| 72B model quality insufficient for briefings | Medium | Medium | 2-week evaluation period; compare local vs Claude outputs side-by-side; adjust escalation thresholds |
| Memory pressure with 3 models + Xcode + browser | Low | High | Budget 65 GB for models (50% of total); monitor with `memory_pressure` command; embedding model unloads first |
| Ollama crashes under sustained concurrent load | Low | Medium | Ollama watchdog (launchd KeepAlive, same as World Tree); health monitor detects and restarts |
| Embedding drift (model update changes vectors) | Low | Low | Re-index on model version change; version stored in brain-index.db metadata |
| Local model hallucination in briefings | Medium | Medium | Confidence signals + mandatory escalation for anything that influences decisions; Evan reviews output for first 2 weeks |
| Cost savings don't materialize (still escalating too much) | Low | Low | Track escalation rate in inference_log; tune thresholds monthly; target <10% escalation rate |
| qwen2.5:72b download takes hours | Low | Low | Download overnight; ~42 GB at ~50 MB/s = ~14 minutes on good connection |

---

## Task Index

| Task | Title | Priority | Phase |
|------|-------|----------|-------|
| TASK-41 | Download qwen2.5:72b + nomic-embed-text models | Critical | Setup |
| TASK-42 | Configure Ollama for concurrent multi-model serving | Critical | Setup |
| TASK-43 | Upgrade Scout to use qwen2.5-coder:32b (verify + benchmark) | High | Setup |
| TASK-44 | Build QualityRouter — task classification and provider routing | High | Core |
| TASK-45 | Build BrainIndexer — chunk + embed + store brain content | High | Core |
| TASK-46 | Build brain_search MCP tool for Claude sessions | High | Core |
| TASK-47 | ContextServer: GET /brain/search endpoint | High | Core |
| TASK-48 | Wire scheduled agents to use local 72B (morning brief) | High | Agents |
| TASK-49 | Wire scheduled agents to use local 72B (drift detector) | High | Agents |
| TASK-50 | Wire scheduled agents to use local 72B (health monitor) | Medium | Agents |
| TASK-51 | Add inference_log table + routing telemetry | Medium | Observability |
| TASK-52 | World Tree Intelligence Dashboard (model status + routing stats) | High | WorldTree |
| TASK-53 | Offline mode detection and graceful degradation | Medium | Resilience |
| TASK-54 | Ollama launchd KeepAlive + watchdog | Medium | Resilience |
| TASK-55 | 2-week quality evaluation — local vs Claude output comparison | High | Validation |

**Sequence constraints:**
- Phase 1 (Setup): TASK-41 → TASK-42 → TASK-43 (sequential — need models before config before benchmarks)
- Phase 2 (Core): TASK-44, 45, 46, 47 can be parallel (independent subsystems). Depend on TASK-42 (models loaded).
- Phase 3 (Agents): TASK-48, 49, 50 depend on TASK-44 (QualityRouter). Also depend on EPIC-CORTANA-3 TASK-15, 16, 17 (agents must exist to reroute). Can be parallel with each other.
- Phase 4 (Observability): TASK-51 can start anytime after TASK-44. TASK-52 depends on TASK-51.
- Phase 5 (Resilience): TASK-53, 54 can start anytime after Phase 1.
- Phase 6 (Validation): TASK-55 starts after Phase 3, runs for 2 weeks.

**Dependency on EPIC-CORTANA-3:**
- TASK-48/49/50 require the scheduled agents (CORTANA-3 TASK-15/16/17) to exist first
- TASK-52 (dashboard) can surface data from CORTANA-3's briefing/alert system
- These epics are complementary, not sequential — Phase 1-2 of this epic can run in parallel with CORTANA-3

---

## Model Download Plan

```bash
# Run these — total download ~42.5 GB, ~15-20 minutes on good connection
ollama pull qwen2.5:72b              # ~47 GB — primary reasoning model
ollama pull nomic-embed-text       # ~274 MB — embedding model

# Verify all 3 models loaded
ollama list
# Expected: qwen2.5:72b, qwen2.5-coder:32b, nomic-embed-text

# Pre-warm (load into GPU memory)
curl -s http://localhost:11434/api/generate -d '{"model":"qwen2.5:72b","prompt":"hello","stream":false}' > /dev/null
curl -s http://localhost:11434/api/generate -d '{"model":"qwen2.5-coder:32b","prompt":"hello","stream":false}' > /dev/null
curl -s http://localhost:11434/api/embed -d '{"model":"nomic-embed-text","input":"hello"}' > /dev/null

# Verify all loaded
ollama ps
# Should show 3 models, total ~62 GB, all GPU-resident
```

---

## Memory Budget

| Component | RAM | Notes |
|-----------|-----|-------|
| qwen2.5:72b | ~49 GB | Primary reasoning |
| qwen2.5-coder:32b | ~20 GB | Code intelligence (Scout) |
| nomic-embed-text | ~300 MB | Embeddings |
| **Model subtotal** | **~69 GB** | **54% of 128 GB** |
| macOS + system | ~8 GB | Kernel, WindowServer, etc. |
| World Tree | ~200 MB | SwiftUI app |
| Xcode (when open) | ~4-8 GB | Build server, indexing |
| Browser + misc | ~4-8 GB | Tabs, services |
| **System subtotal** | **~16-24 GB** | |
| **Headroom** | **~35-43 GB** | Room for spikes, large builds |

This is comfortable. No memory pressure expected under normal workloads.

---

*Epic planned 2026-03-29. 💠*
