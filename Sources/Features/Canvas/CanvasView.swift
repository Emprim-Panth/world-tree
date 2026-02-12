import SwiftUI
import GRDB

/// Main canvas area — displays the selected branch's conversation.
/// Supports split view for side-by-side branch comparison.
struct CanvasView: View {
    @EnvironmentObject var appState: AppState
    @State private var splitBranchId: String?
    @State private var showProcessMonitor = false

    var body: some View {
        VStack(spacing: 0) {
            if let branchId = appState.selectedBranchId {
                if let splitId = splitBranchId {
                    // Split view — two branches side by side
                    HSplitView {
                        BranchView(branchId: branchId)
                            .id(branchId)

                        BranchView(branchId: splitId)
                            .id(splitId)
                    }
                } else {
                    BranchView(branchId: branchId)
                        .id(branchId)
                }
            } else {
                emptyState
            }

            // Process monitor bar (toggleable)
            if showProcessMonitor {
                Divider()
                ProcessMonitorBar()
                    .frame(height: 28)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Split view toggle
                if appState.selectedBranchId != nil {
                    Button {
                        toggleSplit()
                    } label: {
                        Image(systemName: splitBranchId != nil ? "rectangle" : "rectangle.split.2x1")
                            .font(.caption)
                    }
                    .help(splitBranchId != nil ? "Close split view" : "Split view")
                }

                // Process monitor toggle
                Button {
                    showProcessMonitor.toggle()
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption)
                }
                .help("Process monitor")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 48))
                .foregroundStyle(.cyan.opacity(0.5))

            Text("Select a branch or create a new tree")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Cmd+N to create a new tree")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleSplit() {
        if splitBranchId != nil {
            splitBranchId = nil
        } else {
            // Try to pick a sibling branch for comparison
            guard let branchId = appState.selectedBranchId,
                  let branch = try? TreeStore.shared.getBranch(branchId) else { return }
            let siblings = (try? TreeStore.shared.getSiblings(of: branchId)) ?? []
            splitBranchId = siblings.first?.id
        }
    }
}

// MARK: - Process Monitor Bar

/// Compact bar showing active processes and provider status.
struct ProcessMonitorBar: View {
    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var eventCount: Int = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Active provider
            HStack(spacing: 4) {
                Circle()
                    .fill(providerManager.isRunning ? .green : .gray)
                    .frame(width: 6, height: 6)

                Text(providerManager.activeProviderName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                if providerManager.isRunning {
                    Text("running")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }

            Divider()
                .frame(height: 14)

            // Provider health indicators
            ForEach(providerManager.providers, id: \.identifier) { provider in
                HStack(spacing: 3) {
                    Circle()
                        .fill(healthColor(for: provider.identifier))
                        .frame(width: 5, height: 5)

                    Text(provider.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Event count (refreshed periodically, not on every render)
            Text("Events: \(eventCount)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .background(.bar)
        .onAppear { refreshEventCount() }
        .task {
            // Refresh every 5 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                refreshEventCount()
            }
        }
    }

    private func healthColor(for identifier: String) -> Color {
        switch providerManager.healthStatus[identifier] {
        case .available: return .green
        case .degraded: return .yellow
        case .unavailable: return .red
        case .none: return .gray
        }
    }

    private func refreshEventCount() {
        eventCount = (try? DatabaseManager.shared.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM canvas_events") ?? 0
        }) ?? 0
    }
}
