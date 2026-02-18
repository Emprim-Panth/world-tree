import SwiftUI

// MARK: - Template Picker

/// Grid of workflow templates shown when creating a new branch.
/// Selecting a template pre-configures branch type, system context, and initial prompt.
struct TemplatePicker: View {
    let onSelect: (WorkflowTemplate) -> Void
    let onSkip: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(.cyan)
                Text("Choose a Workflow")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }

            Text("Templates pre-configure your branch for common tasks")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Template grid — scrollable so it's safe if template list grows
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(WorkflowTemplate.all) { template in
                        TemplateCard(template: template)
                            .onTapGesture { onSelect(template) }
                    }
                }
            }

            Divider()

            // Skip option — styled as a clear button, not invisible text
            Button {
                onSkip()
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("Start blank conversation")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .frame(width: 480)
        .frame(minHeight: 300, maxHeight: 600)
    }
}

// MARK: - Template Card

struct TemplateCard: View {
    let template: WorkflowTemplate

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: template.icon)
                    .font(.title3)
                    .foregroundStyle(.cyan)

                Spacer()

                // Branch type badge
                Text(template.branchType.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(branchTypeColor.opacity(0.2))
                    .foregroundStyle(branchTypeColor)
                    .cornerRadius(4)
            }

            Text(template.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Text(template.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Sandbox indicator
            HStack(spacing: 4) {
                Image(systemName: sandboxIcon)
                    .font(.system(size: 8))
                Text(template.sandboxProfile)
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovering ? Color.cyan.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    private var branchTypeColor: Color {
        switch template.branchType {
        case .conversation: return .blue
        case .implementation: return .orange
        case .exploration: return .purple
        }
    }

    private var sandboxIcon: String {
        switch template.sandboxProfile {
        case "airgapped": return "lock.shield.fill"
        case "workspace": return "folder.badge.gearshape"
        default: return "lock.open.fill"
        }
    }
}
