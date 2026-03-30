# TASK-12: Delete Shared chat infrastructure

**Status:** done
**Priority:** critical
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 1 — Deletion
**Depends on:** TASK-11

## Context

Remove all Shared-level files that exist to support the chat/streaming/agent infrastructure.

## Files to Delete

```
Shared/ActiveStreamRegistry.swift
Shared/BranchWindowOwnershipRegistry.swift
Shared/Components/ArtifactRendererView.swift
Shared/Components/ChoiceBlockView.swift
Shared/Components/CodeBlockView.swift
Shared/Components/ContextGauge.swift
Shared/Components/DiffView.swift
Shared/Components/KeyboardHandlingTextEditor.swift
Shared/Components/ModelBadge.swift
Shared/Components/ProviderBadge.swift
Shared/Components/WebViewPool.swift
Shared/FactoryStatusChip.swift
Shared/GlobalStreamRegistry.swift
Shared/KeychainHelper.swift
Shared/LocalAgentIdentity.swift
Shared/ModelPickerButton.swift
Shared/OpenAIKeyStore.swift
Shared/ProcessingRegistry.swift
Shared/StreamRecoveryCoordinator.swift
Shared/StreamRecoveryStore.swift
```

## Files to Keep

```
Shared/Components/StatusBadge.swift
Shared/Components/HeartbeatIndicator.swift
Shared/Utilities.swift
Shared/Utilities/AnyCodable.swift
Shared/Constants.swift
```

## Acceptance Criteria

- [ ] All listed files deleted
- [ ] Kept files intact and untouched
- [ ] No new files created as replacements

## Notes

Do not replace KeychainHelper with a stub — there is no API key storage needed in the simplified app.
