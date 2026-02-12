import SwiftUI

// MARK: - HITL Approval Sheet

/// Human-in-the-loop approval dialog for destructive operations.
/// Shows risk assessment details and requires explicit confirmation.
struct ApprovalSheet: View {
    let assessment: ToolGuard.Assessment
    let command: String
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Warning icon
            Image(systemName: riskIcon)
                .font(.system(size: 36))
                .foregroundStyle(riskColor)
                .padding(.top, 8)

            // Title
            Text("Security Gate")
                .font(.title2)
                .fontWeight(.bold)

            // Risk badge
            HStack(spacing: 6) {
                Circle()
                    .fill(riskColor)
                    .frame(width: 8, height: 8)
                Text(riskLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(riskColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(riskColor.opacity(0.1))
            .cornerRadius(8)

            // Details
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Tool", value: assessment.toolName)
                DetailRow(label: "Risk", value: assessment.reason)

                // Command preview
                Text("Command:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
            }
            .padding(.horizontal)

            Divider()

            // Actions
            HStack(spacing: 16) {
                Button("Deny") {
                    onDeny()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Approve Execution") {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .tint(riskColor)
                .controlSize(.large)
            }
            .padding(.bottom)
        }
        .frame(width: 400)
        .padding()
    }

    private var riskIcon: String {
        switch assessment.riskLevel {
        case .critical: return "exclamationmark.octagon.fill"
        case .destructive: return "exclamationmark.triangle.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .safe: return "checkmark.shield.fill"
        }
    }

    private var riskColor: Color {
        switch assessment.riskLevel {
        case .critical: return .red
        case .destructive: return .orange
        case .caution: return .yellow
        case .safe: return .green
        }
    }

    private var riskLabel: String {
        switch assessment.riskLevel {
        case .critical: return "CRITICAL"
        case .destructive: return "DESTRUCTIVE"
        case .caution: return "CAUTION"
        case .safe: return "SAFE"
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}
