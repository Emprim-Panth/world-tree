# TASK-152: One-Click Terminal Focus

**Priority**: medium
**Status**: Done
**Category**: feature
**Epic**: Agent Orchestration Dashboard
**Sprint**: 3
**Agent**: scotty
**Complexity**: S
**Dependencies**: TASK-136

## Description

When clicking an agent session card, bring the corresponding tmux pane to focus in the active terminal emulator (Ghostty or Terminal.app). Enables instant transition from "I see a problem" to "I'm looking at the terminal."

## Files to Modify

- **Modify**: `Sources/Features/CommandCenter/AgentStatusCard.swift` — Add tap action
- **Modify**: `Sources/Core/Terminal/BranchTerminalManager.swift` — Add focusSession method

## Implementation

### Terminal Focus Strategy

1. From AgentSession, resolve the tmux session name:
   - Dispatch sessions: match via `dispatch_id` → `canvas_dispatches.cli_session_id` → tmux session name pattern
   - Interactive sessions: match via session_id prefix in tmux session list
   - Fallback: match by working_directory against tmux session pwd

2. Focus the tmux pane:
   ```bash
   tmux select-window -t {session_name}
   tmux select-pane -t {session_name}
   ```

3. Bring terminal emulator to front:
   ```swift
   // Try Ghostty first, then Terminal.app
   if let ghostty = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" }) {
       ghostty.activate()
   } else if let terminal = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
       terminal.activate()
   }
   ```

### DaemonService Integration

`DaemonService.tmuxSessions` already lists active tmux sessions. Cross-reference with agent session to find the right pane.

## Acceptance Criteria

- [ ] Clicking active agent card focuses corresponding tmux pane
- [ ] Ghostty is preferred over Terminal.app
- [ ] Handles case where tmux session no longer exists (show "Session not found" toast)
- [ ] Does not crash when no terminal emulator is running
- [ ] Works for both dispatch and interactive sessions
