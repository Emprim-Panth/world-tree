# TASK-11: Delete Feature chat modules

**Status:** done
**Priority:** critical
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 1 — Deletion
**Depends on:** TASK-10

## Context

Remove all Feature modules that belong to the chat/conversation engine: Canvas (dir), Document, Sidebar, Terminal, Agents, Brain (chat views), MCPTools, Projects, Templates, Context, Cortana, Dashboard features.

Also remove the 17 CommandCenter sub-sections that reference deleted systems (see epic FRD for full list).

## Files to Delete

```
Features/Agents/AgentListView.swift
Features/Agents/StarfleetDispatchSheet.swift
Features/Agents/StarfleetRosterView.swift
Features/Brain/BrainView.swift
Features/Brain/KnowledgeView.swift
Features/Canvas/                          (entire directory — may be empty)
Features/Context/ContextInspectorView.swift
Features/Cortana/                         (entire directory — all files)
Features/Dashboard/EventTimelineView.swift
Features/Dashboard/GlobalSearchView.swift
Features/Document/DocumentEditorView.swift
Features/Document/DocumentModel.swift
Features/Document/DocumentSectionView.swift
Features/Document/ProposalCardView.swift
Features/Document/SingleDocumentView.swift
Features/Document/SkillsPaletteView.swift
Features/MCPTools/CodexMCPConfigManager.swift
Features/MCPTools/MCPConfigManager.swift
Features/MCPTools/MCPToolsView.swift
Features/Projects/ProjectDocsView.swift
Features/Projects/ProjectListView.swift
Features/Projects/ProjectRowView.swift
Features/Settings/CortanaControlMatrix.swift
Features/Settings/CortanaControlView.swift
Features/Settings/PencilSettingsView.swift
Features/Sidebar/ActiveJobsSection.swift
Features/Sidebar/SidebarView.swift
Features/Sidebar/SidebarViewModel.swift
Features/Sidebar/TreeNodeView.swift
Features/Templates/TemplatePicker.swift
Features/Templates/WorkflowTemplate.swift
Features/Terminal/TerminalView.swift

Features/CommandCenter/ActiveWorkSection.swift
Features/CommandCenter/AgentStatusBoard.swift
Features/CommandCenter/AgentStatusCard.swift
Features/CommandCenter/AttentionPanel.swift
Features/CommandCenter/ConflictWarningBanner.swift
Features/CommandCenter/CoordinatorSection.swift
Features/CommandCenter/CortanaOpsSection.swift
Features/CommandCenter/DecisionReviewSection.swift
Features/CommandCenter/DiffReviewSheet.swift
Features/CommandCenter/DiffReviewView.swift
Features/CommandCenter/EventRulesSheet.swift
Features/CommandCenter/FactoryFloorView.swift
Features/CommandCenter/FactoryPipelineView.swift
Features/CommandCenter/JobOutputInspectorView.swift
Features/CommandCenter/LiveStreamsSection.swift
Features/CommandCenter/PencilDesignSection.swift
Features/CommandCenter/PencilDiffView.swift
Features/CommandCenter/SessionHealthBadge.swift
Features/CommandCenter/SessionMemoryView.swift
Features/CommandCenter/StarfleetActivitySection.swift
Features/CommandCenter/TokenDashboardView.swift
```

## Acceptance Criteria

- [ ] All files listed above are deleted
- [ ] Empty directories removed after deletion
- [ ] Features/Settings/ retains only `SettingsView.swift`
- [ ] Features/CommandCenter/ retains only: `CommandCenterView.swift`, `CommandCenterViewModel.swift`, `CompassProjectCard.swift`, `DispatchActivityView.swift`, `DispatchSheet.swift`
- [ ] Features/Brain/ is empty (BrainEditorView built fresh in TASK-19)

## Notes

CommandCenterView.swift and CommandCenterViewModel.swift will have broken references after this deletion. That is expected — they get repaired in TASK-17.
