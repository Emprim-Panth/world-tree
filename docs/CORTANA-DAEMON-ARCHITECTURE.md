# Cortana Daemon + World Tree Cockpit

## Decision

Build Cortana as a dedicated local daemon and keep World Tree as the primary cockpit.

Do not put all of Cortana inside World Tree.
Do not replace World Tree wholesale with OpenClaude-Swift.
Do use the OpenClaude-style daemon model as the always-on control plane.

## Executive Summary

The best architecture is a split system:

- `Cortana Core Daemon`
  - always-on
  - launchd-managed
  - owns Telegram, scheduling, machine permissions, native macOS control, automation, local chat API
- `World Tree Cockpit`
  - interactive command center
  - branch/tree workspace
  - provider switching and project orchestration UI
  - deep context editing, inspection, and supervision

This gives Cortana two different strengths:

- daemon for persistence, channels, and machine authority
- World Tree for human steering, project context, and execution visibility

## Current Build Status

The first foundation is already in place:

- OpenClaude-style daemon builds and runs locally as Cortana
- launchd supervision is installed for the separate app runtime
- CLI status now self-heals from `daemon.status.json` when `daemon.pid` is missing
- daemon auth now accepts both bearer tokens and World Tree's legacy `x-api-token`
- daemon pathing now supports a Cortana-owned home layout without breaking legacy installs
- local app surface is now exposed as `Cortana Console`, not just Telegram

That means the architecture is no longer theoretical. The daemon can already serve as the persistent local control plane while World Tree remains the cockpit.

## Recommendation

### Best LLM Host

`OpenClaude-style Cortana daemon` is the best host for the always-running Cortana runtime.

Reason:

- daemon-first lifecycle is better for crash recovery, login startup, and background channels
- explicit JSON/file config is better for operator control than app-only `UserDefaults`
- channel manager pattern is better for Telegram/iMessage/web ingress
- native macOS integrations are already modeled as first-class subsystems

### Best Human Interface

`World Tree` remains the best primary interface for active use.

Reason:

- stronger workspace model
- stronger branch/session context
- better project and terminal supervision
- better provider routing across Claude/Codex
- already aligned with current Cortana ecosystem

### Final Position

The final build should be:

- `Cortana runs in a dedicated daemon`
- `World Tree controls, observes, and extends that daemon`

## Why Not All Eggs In World Tree

World Tree is a rich app, but it is still a foreground-heavy command environment.

Problems if Cortana only lives there:

- app lifecycle and daemon lifecycle are coupled
- background channels depend on app health
- crash domains are shared with the UI
- full-machine service behavior becomes harder to reason about

World Tree should not be the only body Cortana has.

## Why Not Just Use OpenClaude As-Is

OpenClaude-Swift proved the shape, not the finish.

Current issues:

- shipped with a broken local package dependency
- identity/runtime still partly Friday/OpenClaude-shaped
- status and PID plumbing are inconsistent
- runtime surface is broad, but integration with the current Cortana ecosystem is immature

Conclusion:

Use it as architectural reference and donor code, not as the final product without refactoring.

## System Goals

1. Cortana is always available after login, crash, or reboot.
2. Telegram can reach Cortana reliably and trigger real local actions.
3. Cortana can control the Mac locally with explicit permission boundaries.
4. World Tree can direct Claude and Codex as execution engines.
5. Local chat exists beyond Telegram.
6. Human-visible command and background autonomy are separated cleanly.
7. Failures in one subsystem do not take down the entire stack.

## Non-Goals

1. A single giant app that owns every concern.
2. Replacing World Tree’s branch model with a generic daemon chat log.
3. Giving Telegram direct raw shell access without policy enforcement.
4. Letting multiple overlapping Cortana identities compete on the same Mac.

## Target Architecture

```text
Telegram / Local Chat UI / Menu Bar / Voice
                |
                v
        Cortana Core Daemon
    ---------------------------
    Identity + Policy Engine
    Channel Manager
    Automation / Scheduler
    Native Mac Control Layer
    Provider Control Layer
    Event / State Journal
    World Tree Bridge
    ---------------------------
                |
       -------------------
       |                 |
       v                 v
  World Tree         Native Mac
  Cockpit            Integrations
  - trees/branches   - accessibility
  - project ops      - screenshots
  - provider UI      - notifications
  - terminal UI      - app control
  - supervision      - keychain
```

## Component Boundaries

### Cortana Core Daemon

Owns:

- canonical Cortana identity
- inbound channel handling
- local operator API
- launchd lifecycle
- proactive automation
- machine permissions and native integrations
- routing requests to the right execution backend
- persistent status and health

Should expose:

- `/health`
- `/api/status`
- `/api/chat`
- `/api/events`
- `/api/channels/telegram`
- `/api/mac/*`
- `/api/providers/*`
- `/api/worldtree/*`

### World Tree Cockpit

Owns:

- project/branch/tree data model
- human-facing workspace UI
- terminal and implementation views
- provider model selection UX
- project context inspection
- command center and supervision surfaces
- long-form interactive work sessions

Should consume daemon APIs rather than re-own the same background concerns.

### Gateway

Owns:

- cross-device coordination
- project intent
- terminals at ecosystem scale
- sync queue
- priority/throttle policy

Should remain a coordination service, not Cortana’s identity host.

## Control Model

### Who Owns the Voice

Only one runtime owns the Cortana voice: `Cortana Core Daemon`.

World Tree must not invent a separate Cortana persona path in parallel.
It should request identity/policy/runtime behavior from the daemon or share the same identity package.

### Who Owns Provider Dispatch

Provider dispatch should be split:

- daemon decides broad execution mode
  - answer directly
  - hand off to World Tree
  - invoke Claude engine
  - invoke Codex engine
  - use local native capability
- World Tree decides branch/session/project context details for interactive execution

## Local Chat Surfaces

Telegram alone is not enough.

Add at least three local conversation surfaces:

1. `Menu bar quick chat`
   - short local prompts
   - immediate machine commands
   - status and briefing access

2. `World Tree Cortana console`
   - rich local conversation
   - context-aware requests
   - handoff into branches/projects

3. `Local web chat`
   - daemon-served localhost UI
   - available when World Tree is closed
   - good for quick control from browser or another local device

Optional:

4. `Voice mode`
   - local speech input/output for hands-busy workflows

## Telegram Design

Telegram should reach the daemon, not the World Tree UI directly.

Telegram responsibilities:

- briefings
- direct conversation
- quick commands
- approval requests
- status queries
- wake/summon flow when you are away from the Mac

Telegram should not:

- bypass policy
- drive raw shell directly
- create uncontrolled long-running work without routing

### Telegram Request Flow

```text
Telegram message
  -> Cortana daemon
    -> classify intent
      -> direct answer
      -> local Mac action
      -> World Tree branch action
      -> Claude/Codex execution
      -> request approval
```

### Telegram Permission Model

Telegram must have enough authority to control the Mac through Cortana, but only through daemon policy.

Recommended policy tiers:

- `conversation`
  - answer, summarize, brief
- `safe_control`
  - open app, inspect state, capture context, trigger workflows
- `supervised_execution`
  - run project actions through World Tree/gateway
- `dangerous_execution`
  - blocked unless explicitly approved

## Mac Control Layer

For “full control of the Mac,” the daemon should own a native capability layer.

Required capabilities:

- Accessibility
  - read focused app/window/selection
  - drive UI actions where appropriate
- ScreenCaptureKit
  - inspect visible context
  - support visual verification
- NSWorkspace / AppKit
  - launch, focus, and inspect apps
- Keychain
  - manage secrets
- Notifications
  - local user-facing prompts
- AppleScript / Messages / Mail bridges where needed
- File watching
  - react to local system/project changes

Important:

Mac control should be implemented as explicit tools with policy gating and audit logging, not as a vague “agent can do anything” promise.

## Web Search

The daemon can support light local-first web actions, but should not become a browser automation monster by default.

Recommended split:

- `easy web search`
  - daemon can do directly via web/search capability
- `interactive browser workflows`
  - route to World Tree or a specialized automation service

This matches reality:

- direct info retrieval is cheap
- robust browser control needs stronger tooling and supervision

## Codex and Claude Control

World Tree should remain the primary place to steer Codex and Claude.

Daemon responsibilities:

- choose engine family when appropriate
- maintain provider health and availability
- expose provider mode API
- route Telegram/local chat into the right engine

World Tree responsibilities:

- select model/provider for branch work
- attach project context
- manage session/branch continuity
- display execution state and outputs

### Recommended Provider Pattern

- `daemon provider router`
  - simple policy and availability layer
- `World Tree provider orchestrator`
  - high-context execution layer

### Execution Modes

1. `daemon direct`
   - quick answers, small actions

2. `world tree interactive`
   - coding, planning, multi-step project work

3. `delegated execution`
   - daemon asks World Tree to create/use branch session with Claude or Codex

4. `background automation`
   - daemon runs scheduled flows with explicit engine choice and resource limits

## Identity Strategy

Do not maintain two different Cortanas.

Use a single identity package:

- `Cortana identity bundle`
  - soul
  - persona
  - operating rules
  - user context
  - permissions philosophy
  - style guides

World Tree and daemon should both consume it.

Recommended storage:

- versioned identity files in a shared Cortana config directory
- runtime caching in both systems

Avoid:

- identity hard-coded in one place
- different sign-offs/tone/rules between systems

## State and Persistence

The daemon needs operator-grade persistence.

Required state:

- health
- boot nonce
- pid / lock
- crash markers
- last interaction
- scheduled jobs
- channel connectivity
- pending approvals
- audit trail
- provider health

World Tree keeps:

- trees
- branches
- conversation history
- project context
- terminal/session data

Shared state should be bridged, not duplicated blindly.

## Reliability Design

### Launch

The daemon must be launchd-managed with:

- `RunAtLoad`
- `KeepAlive`
- bounded restart throttle
- dedicated stdout/stderr logs

### Crash Recovery

On launch:

- recover interrupted work records
- restore channel state
- rebuild provider health
- reconcile stale pid/status files
- reconnect World Tree bridge
- resume scheduled automation

### Failure Isolation

Separate crash domains:

- daemon crash should not destroy World Tree project state
- World Tree crash should not kill Telegram or briefings
- gateway crash should not kill local Cortana daemon

This is the main reason to split the system.

## Security and Permissions

“Full permissions” should mean:

- the daemon has the required macOS grants
- every powerful action still flows through policy and logging

Required grants:

- Accessibility
- Screen Recording
- Notifications
- Full Disk Access where truly needed
- Keychain access
- microphone/speech if voice is enabled

Policy requirements:

- classify action risk
- gate dangerous actions
- log all machine-control actions
- require confirmation for destructive or external actions

## Recommended Build Plan

### Phase 1: Architecture Unification

- define shared Cortana identity bundle
- define daemon API contract
- define World Tree bridge contract
- define provider-routing contract
- normalize daemon home under Cortana-owned paths with compatibility fallbacks

### Phase 2: Cortana Core Daemon

- fork or refactor OpenClaude-style daemon into Cortana-specific runtime
- strip Friday/OpenClaude naming
- fix pid/status inconsistency
- harden launchd lifecycle
- expose local API + SSE
- preserve World Tree compatibility while migrating auth and routing contracts

### Phase 3: World Tree Integration

- make World Tree consume daemon status/events
- move Telegram/background concerns out of World Tree-specific paths
- keep branch/project UX in World Tree
- add “Cortana Console” screen in World Tree

### Phase 4: Local Conversation Surfaces

- menu bar quick chat
- localhost web chat
- World Tree Cortana console
- optional voice mode

### Phase 5: Provider Governance

- daemon chooses route
- World Tree controls branch execution
- explicit Claude/Codex engine controls
- approval and audit policy for Telegram-triggered actions

## Acceptance Criteria

The design is successful when:

1. Telegram can message Cortana with World Tree closed.
2. Cortana can inspect and control the Mac through native tools.
3. World Tree can direct Claude and Codex through the same Cortana ecosystem.
4. A Mac reboot restores Cortana automatically.
5. A World Tree crash does not kill Cortana’s background presence.
6. A daemon crash does not destroy World Tree’s project state.
7. Local chat exists without requiring Telegram.
8. Only one Cortana identity is visible across every surface.

## Immediate Next Engineering Moves

1. Make World Tree consume daemon auth and status as the canonical control plane instead of treating the daemon as optional glue.
2. Move the shared identity bundle into a single Cortana-owned directory and point both runtimes at it.
3. Add explicit daemon endpoints for World Tree-controlled Codex and Claude execution so the split between control plane and cockpit is enforced in code.
4. Repackage and reinstall the local app so `Cortana Console` becomes the stable on-Mac chat surface.

## Final Recommendation

Yes, the `OpenClaude-style daemon runtime` is the best bet for always-on Cortana.

No, `OpenClaude as-is` is not the final product.

Yes, `World Tree` should remain the primary command cockpit and execution surface.

The final build should therefore be:

- `Cortana Daemon` for always-on intelligence and machine control
- `World Tree` for command, supervision, project context, and provider orchestration
- `Telegram + local chat surfaces` as clients of the daemon

That is the strongest architecture for reliability, control, and long-term maintainability. 💠
