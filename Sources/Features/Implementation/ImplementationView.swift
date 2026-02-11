import SwiftUI

/// Live view of a daemon-dispatched implementation branch.
/// Shows context at top, streaming log output below.
struct ImplementationView: View {
    let branch: Branch
    @StateObject private var viewModel: ImplementationVM

    init(branch: Branch) {
        self.branch = branch
        _viewModel = StateObject(wrappedValue: ImplementationVM(branch: branch))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Content
            if branch.status == .completed || viewModel.phase == .done {
                completedView
            } else {
                liveView
            }
        }
        .onAppear {
            if branch.daemonTaskId != nil && branch.status == .active {
                viewModel.resume()
            }
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(branch.displayTitle)
                    .font(.headline)

                HStack(spacing: 8) {
                    phaseIndicator
                    if let model = branch.model {
                        ModelBadge(model: model)
                    }
                    if let taskId = viewModel.taskId {
                        Text(taskId)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospaced()
                    }
                }
            }

            Spacer()

            if viewModel.phase == .running {
                Button("Open Terminal") {
                    viewModel.openInTerminal()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch viewModel.phase {
        case .preparing:
            Label("Preparing", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .dispatching:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Dispatching...")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .running:
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .completing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Completing...")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .done:
            Label("Complete", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    // MARK: - Live Log View

    private var liveView: some View {
        VStack(spacing: 0) {
            // Context snapshot (collapsible)
            if let context = branch.contextSnapshot {
                DisclosureGroup("Context") {
                    ScrollView {
                        Text(context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            // Log output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(lineColor(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .onChange(of: viewModel.logLines.count) { _, _ in
                    if let lastIdx = viewModel.logLines.indices.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastIdx, anchor: .bottom)
                        }
                    }
                }
            }

            // Dispatch button if not yet started
            if viewModel.phase == .preparing {
                Button("Dispatch to Daemon") {
                    Task { await viewModel.dispatch() }
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    // MARK: - Completed View

    private var completedView: some View {
        VStack(spacing: 16) {
            if let summary = branch.summary {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Summary", systemImage: "doc.text")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.05))
                .cornerRadius(8)
                .padding(.horizontal, 16)
            }

            if !viewModel.logLines.isEmpty {
                DisclosureGroup("Full Log (\(viewModel.logLines.count) lines)") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 400)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                    .cornerRadius(6)
                }
                .padding(.horizontal, 16)
            }

            Spacer()
        }
        .padding(.top, 16)
    }

    // MARK: - Helpers

    private func lineColor(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fail") { return .red }
        if lower.contains("warn") { return .yellow }
        if lower.contains("success") || lower.contains("complete") { return .green }
        return .primary.opacity(0.8)
    }
}
