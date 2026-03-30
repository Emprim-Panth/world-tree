# TASK-10: Delete Core chat modules

**Status:** done
**Priority:** critical
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 1 — Deletion
**Depends on:** TASK-9

## Context

Remove all Core modules that exist solely to support the chat/conversation engine. These are: Claude, Branching, Cache, Context, Coordinator, Cortana, Daemon, Jobs, Pencil, Plugin, ProjectDocs, ProjectIntelligence, Providers, Sandbox, Security, SlashCommands, Terminal, Voice, Brain (chat), Events. Also remove GlobalHotKey.swift and PermissionsService.swift.

## Files to Delete

```
Core/Brain/BrainStore.swift
Core/Branching/BranchAutoNamer.swift
Core/Branching/BranchExportService.swift
Core/Cache/StreamCacheManager.swift
Core/Claude/AnthropicClient.swift
Core/Claude/AnthropicTypes.swift
Core/Claude/ClaudeBridge.swift
Core/Claude/ClaudeService.swift
Core/Claude/ConversationStateManager.swift
Core/Claude/StallRecoveryWatcher.swift
Core/Claude/SynthesisService.swift
Core/Claude/ToolDefinitions.swift
Core/Claude/ToolExecutor.swift
Core/Context/BranchSummarizer.swift
Core/Context/CLISessionReader.swift
Core/Context/ContextPressureEstimator.swift
Core/Context/ContextProvenance.swift
Core/Context/ConversationScorer.swift
Core/Context/DecisionDetector.swift
Core/Context/MemoryService.swift
Core/Context/SendContextBuilder.swift
Core/Context/SessionRotator.swift
Core/Coordinator/CoordinatorActor.swift
Core/Coordinator/CoordinatorStore.swift
Core/Cortana/CortanaPlannerStore.swift
Core/Daemon/DaemonChannel.swift
Core/Daemon/DaemonService.swift
Core/Daemon/DaemonSocket.swift
Core/Daemon/LogTailer.swift
Core/Daemon/WTCommandBridge.swift
Core/Events/WorldTreeEvent.swift
Core/GlobalHotKey.swift
Core/Jobs/JobModels.swift
Core/Jobs/JobOutputStreamStore.swift
Core/Jobs/JobQueue.swift
Core/Pencil/PencilConnectionStore.swift
Core/Pencil/PencilMCPClient.swift
Core/Pencil/PencilModels.swift
Core/PermissionsService.swift
Core/Plugin/PluginServer.swift
Core/ProjectDocs/ProjectDocsStore.swift
Core/ProjectIntelligence/ProjectCache.swift
Core/ProjectIntelligence/ProjectContextLoader.swift
Core/ProjectIntelligence/ProjectMetrics.swift
Core/ProjectIntelligence/ProjectModels.swift
Core/ProjectIntelligence/ProjectRefreshService.swift
Core/ProjectIntelligence/ProjectScanner.swift
Core/Providers/AgentSDKProvider.swift
Core/Providers/AnthropicAPIProvider.swift
Core/Providers/CLIStreamParser.swift
Core/Providers/ClaudeCodeAuthManager.swift
Core/Providers/ClaudeCodeProvider.swift
Core/Providers/CodexCLIProvider.swift
Core/Providers/CortanaIdentity.swift
Core/Providers/CortanaWorkflowDispatchService.swift
Core/Providers/CortanaWorkflowPlanner.swift
Core/Providers/CortanaWorkflowRouter.swift
Core/Providers/DispatchRouter.swift
Core/Providers/DispatchSupervisor.swift
Core/Providers/LLMProvider.swift
Core/Providers/ModelCatalog.swift
Core/Providers/OllamaClient.swift
Core/Providers/OllamaProvider.swift
Core/Providers/ProviderManager.swift
Core/Providers/RemoteWorldTreeProvider.swift
Core/Sandbox/SandboxProfile.swift
Core/Security/ApprovalCoordinator.swift
Core/Security/ApprovalSheet.swift
Core/Security/FileDiffSheet.swift
Core/Security/PermissionStore.swift
Core/Security/ToolGuard.swift
Core/Server/AuthRateLimiter.swift
Core/Server/PeekabooBridgeServer.swift
Core/Server/SubscriptionManager.swift
Core/Server/TokenBroadcaster.swift
Core/Server/WebSocketHandler.swift
Core/Server/WebSocketProtocol.swift
Core/Server/WorldTreeServer.swift
Core/SlashCommands/SlashCommandRegistry.swift
Core/Terminal/BranchTerminalManager.swift
Core/Voice/VoiceService.swift
```

## Acceptance Criteria

- [ ] All files listed above are deleted
- [ ] Empty directories removed after deletion
- [ ] `xcodegen` runs without error (project.yml may need updating in TASK-14 first — if build fails, track error and continue to TASK-14)
- [ ] Build errors from deleted files are expected and documented — do NOT attempt to fix them by stubbing or reimplementing. Mark them for resolution in TASK-14/15/16.

## Notes

Delete files directly. Do not stub out interfaces, do not leave "// TODO: remove" comments, do not create empty files. Deleted means gone.

If xcodegen fails because project.yml still references deleted paths, note the failure and proceed to TASK-14 before attempting to build.
