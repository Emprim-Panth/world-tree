# TASK-109: Accessibility gaps — full remediation

**Priority**: medium
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Critical+high a11y fixes — button traits on CompassProjectCard, dispatch hint, icon labels on DocumentSectionView, radio button traits in Settings, state-aware mic labels in VoiceControl, status circle labels
**Category**: accessibility
**Source**: QA Audit Wave 3

## Description
Comprehensive accessibility audit found 24 issue categories across 47 view files. Only 22/47 UI files have any accessibility modifiers (78 total). Critical gaps include interactive elements without traits, missing labels on icon buttons, color-only indicators, and no keyboard navigation support.

## Critical Issues (5)
- CompassProjectCard: onTapGesture without button trait or label
- SidebarView: search scope buttons and project header buttons lack labels
- CommandCenterView: dispatch button missing accessibility grouping
- DocumentSectionView: fork/reply icon buttons without labels
- TreeNodeView: branch icons without sufficient context

## High Issues (6)
- AllTicketsView: status indicator icons without labels
- ActiveWorkSection: status indicators and cancel buttons incomplete
- SettingsView: custom radio buttons lack button traits
- VoiceControlView: icon buttons with color-only state indicators
- CompassProjectCard: color-only status circles (red/green/orange/gray)
- Badge components: color-only state distinction

## Medium Issues (8)
- TicketListView: disclosure state not communicated
- SidebarView: search bar missing keyboard navigation
- DocumentSectionView: missing element grouping
- HeartbeatIndicator: pulse animation visual-only
- DocumentEditorView: fixed font sizes (no Dynamic Type)
- VoiceControlView: no keyboard focus on mic button
- ProjectRowView/AgentListView: indicator icons without descriptions

## Low Issues (6+)
- 40+ instances of fixed .font(.system(size:)) instead of relative sizing
- Missing accessibilityIdentifier on testable elements
- Missing accessibilityAction for custom gestures
- Opacity-based contrast concerns
- Missing accessibilityElement(children:) grouping
- Inconsistent color-only indicators

## Acceptance Criteria
- [ ] All interactive elements have .accessibilityAddTraits(.isButton) or equivalent
- [ ] All icon-only buttons have .accessibilityLabel()
- [ ] All color-only indicators have text/shape alternatives
- [ ] Keyboard navigation works for all primary workflows
- [ ] VoiceOver can navigate all views end-to-end
