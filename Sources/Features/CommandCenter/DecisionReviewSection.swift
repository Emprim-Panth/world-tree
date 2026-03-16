import SwiftUI

/// Section in the Command Center that shows auto-detected decisions pending review.
/// Users can approve (logs to Compass knowledge base) or reject each decision.
struct DecisionReviewSection: View {
    @State private var pendingDecisions: [AutoDecisionStore.AutoDecision] = []
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            if !pendingDecisions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    ForEach(pendingDecisions) { decision in
                        DecisionReviewCard(decision: decision) { action in
                            handleAction(action, for: decision)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear { refresh() }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 13))
                Text("Detected Decisions")
                    .font(.system(size: 13, weight: .semibold))
                Text("(\(pendingDecisions.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if pendingDecisions.count > 1 {
                HStack(spacing: 8) {
                    Button("Approve All") {
                        Task {
                            isProcessing = true
                            await AutoDecisionStore.shared.approveAll()
                            refresh()
                            isProcessing = false
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                    .disabled(isProcessing)

                    Button("Dismiss All") {
                        AutoDecisionStore.shared.rejectAll()
                        refresh()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(isProcessing)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleAction(_ action: DecisionReviewCard.Action, for decision: AutoDecisionStore.AutoDecision) {
        switch action {
        case .approve:
            Task {
                isProcessing = true
                await AutoDecisionStore.shared.approve(decision.id)
                refresh()
                isProcessing = false
            }
        case .reject:
            AutoDecisionStore.shared.reject(decision.id)
            refresh()
        }
    }

    private func refresh() {
        pendingDecisions = AutoDecisionStore.shared.getPending()
    }
}

// MARK: - Decision Review Card

struct DecisionReviewCard: View {
    let decision: AutoDecisionStore.AutoDecision
    let onAction: (Action) -> Void

    enum Action {
        case approve
        case reject
    }

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Summary line
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.blue)
                    .font(.system(size: 11))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text(decision.summary)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(isExpanded ? nil : 2)
                        .onTapGesture { withAnimation { isExpanded.toggle() } }

                    HStack(spacing: 8) {
                        if let project = decision.project {
                            Text(project)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }

                        confidenceBadge

                        Text(decision.createdAt, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    if isExpanded && !decision.rationale.isEmpty
                        && decision.rationale != "No explicit rationale detected." {
                        Text(decision.rationale)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 6) {
                    Button {
                        onAction(.approve)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .help("Approve — log to Compass knowledge base")
                    .accessibilityLabel("Approve decision")

                    Button {
                        onAction(.reject)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.5))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss — not a meaningful decision")
                    .accessibilityLabel("Reject decision")
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var confidenceBadge: some View {
        let pct = Int(decision.confidence * 100)
        let color: Color = pct >= 90 ? .green : pct >= 80 ? .yellow : .orange
        return Text("\(pct)%")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}
