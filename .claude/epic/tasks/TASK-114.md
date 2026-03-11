# TASK-114: Memory leak and retain cycle fixes

**Priority**: high
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Observer cleanup before re-registration in loadDocument(), pendingTasks tracking in DaemonService, VoiceControl closure-based observers
**Category**: stability
**Source**: QA Audit Wave 3 — Memory Profiling

## Description
Memory audit found 13 potential leak vectors across the codebase. Two HIGH severity issues need immediate attention; the rest are MEDIUM/LOW.

## HIGH Priority
1. **DocumentEditorViewModel NotificationCenter observer accumulation** (DocumentEditorView.swift:697-762)
   - `loadDocument()` adds 3 observers each call. Rapid branch navigation accumulates observers until ViewModel deinit.
   - Fix: Remove existing observers before adding new ones in loadDocument(), or use a flag to skip re-registration.

2. **DocumentEditorViewModel streamFlushTimer** (DocumentEditorView.swift:476)
   - Timer stored without guaranteed cancellation on ViewModel deallocation during branch navigation.
   - Fix: Invalidate timer in deinit AND in any navigation-triggered cleanup.

## MEDIUM Priority
3. **DaemonService orphaned Tasks** (DaemonService.swift:48-62) — Timer spawns untracked Tasks every 10s
4. **DaemonService Task.detached with unguarded continuation** (DaemonService.swift:201-245)
5. **VoiceControlViewModel nested Timer+Task spawns** (VoiceControlView.swift:179)
6. **VoiceControlViewModel selector-based NotificationCenter observers** (VoiceControlView.swift:125-137)
7. **CommandCenterViewModel GRDB observation task race** (CommandCenterViewModel.swift:68-101)
8. **ImplementationViewModel 30-min polling task without timeout** (ImplementationViewModel.swift:115-127)
9. **JobQueue pipe handler cleanup race** (JobQueue.swift:114-129)

## LOW Priority
10. **ClaudeCodeProvider double-wrapped Timer+Task** (ClaudeCodeProvider.swift:71-75) — redundant but safe
11. **CrashSentinel singleton timer** — safe for current architecture
12. **DatabaseManager singleton timer** — safe for current architecture

## Acceptance Criteria
- [ ] NotificationCenter observers cleaned up before re-registration in DocumentEditorViewModel
- [ ] Stream flush timer invalidated on all ViewModel lifecycle transitions
- [ ] DaemonService tracks spawned Tasks and cancels on stopMonitoring()
- [ ] No leaked observers or timers detectable via Instruments Leaks template
