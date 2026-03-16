import SwiftUI

// MARK: - Proposal Card View

/// Inline card rendered above the input bar when a complex or risky action needs sign-off.
/// The card shows goal, steps, model routing, scope, and risk — with Approve / Revise / Cancel.
struct ProposalCardView: View {
    let request: ProposalRequest
    let onDecide: (ProposalDecision) -> Void

    @State private var revisedGoal: String = ""
    @State private var isRevising: Bool = false
    @FocusState private var revisionFocused: Bool

    private var artifact: ProposedWorkArtifact { request.artifact }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(riskBorderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { revisedGoal = artifact.goal }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: artifact.riskLevel.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(riskColor)

            Text("Proposal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            // Risk badge
            Text(artifact.riskLevel.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(riskColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(riskColor.opacity(0.12))
                .clipShape(Capsule())

            // Access mode badge
            Label(artifact.accessMode.rawValue, systemImage: artifact.accessMode.icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Goal
            VStack(alignment: .leading, spacing: 4) {
                if isRevising {
                    TextEditor(text: $revisedGoal)
                        .font(.system(size: 12))
                        .frame(minHeight: 44, maxHeight: 80)
                        .focused($revisionFocused)
                        .padding(6)
                        .background(Color.accentColor.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                        .onAppear { revisionFocused = true }
                } else {
                    Text(artifact.goal)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Steps (if any)
            if !artifact.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(artifact.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 5)
                            Text(step)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            // Metadata row
            HStack(spacing: 12) {
                Label(artifact.primaryModel, systemImage: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if let reviewer = artifact.reviewer {
                    Label(reviewer, systemImage: "person.badge.shield.checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let scope = artifact.projectScope {
                    Label(scope, systemImage: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if isRevising {
                Button("Send Revision") {
                    let trimmed = revisedGoal.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDecide(.revised(trimmed.isEmpty ? artifact.goal : trimmed))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel") {
                    isRevising = false
                    revisedGoal = artifact.goal
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else {
                Button("Approve") {
                    onDecide(.approved)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [])

                Button("Revise…") {
                    isRevising = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Cancel") {
                    onDecide(.rejected)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var riskColor: Color {
        switch artifact.riskLevel {
        case .low:    return .green
        case .medium: return .orange
        case .high:   return .red
        }
    }

    private var riskBorderColor: Color {
        switch artifact.riskLevel {
        case .low:    return Color.primary.opacity(0.08)
        case .medium: return Color.orange.opacity(0.25)
        case .high:   return Color.red.opacity(0.35)
        }
    }
}
