import SwiftUI

/// Inline diff component showing a summary with expandable file list and colored hunks.
struct DiffReviewView: View {
    let session: AgentSession
    @State private var diffResult: DiffReviewStore.DiffResult?
    @State private var isLoading = false
    @State private var expandedFiles: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                loadingView
            } else if let diff = diffResult {
                diffContent(diff)
            } else if let error = errorMessage {
                emptyState(error)
            } else {
                emptyState("No diff available")
            }
        }
        .task {
            await loadDiff()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Running git diff...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }

    // MARK: - Empty State

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
    }

    // MARK: - Diff Content

    @ViewBuilder
    private func diffContent(_ diff: DiffReviewStore.DiffResult) -> some View {
        // Header: stats summary
        header(diff)

        // File list
        if diff.files.isEmpty {
            emptyState("No changes found")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(diff.files) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func header(_ diff: DiffReviewStore.DiffResult) -> some View {
        HStack(spacing: 12) {
            if let name = session.agentName {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Text(session.project)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 8) {
                Text("+\(diff.totalAdditions)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)

                Text("-\(diff.totalDeletions)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }

            Text("\(diff.files.count) file\(diff.files.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - File Row

    private func fileRow(_ file: DiffReviewStore.FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header — tap to expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedFiles.contains(file.id) {
                        expandedFiles.remove(file.id)
                    } else {
                        expandedFiles.insert(file.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expandedFiles.contains(file.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    statusBadge(file.status)

                    Text(file.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    HStack(spacing: 4) {
                        if file.additions > 0 {
                            Text("+\(file.additions)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded: diff hunks
            if expandedFiles.contains(file.id) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        hunkView(hunk)
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.controlBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Status Badge

    private func statusBadge(_ status: DiffReviewStore.FileStatus) -> some View {
        Text(status.rawValue)
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.bold)
            .foregroundStyle(statusColor(status))
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(statusColor(status).opacity(0.15))
            )
    }

    private func statusColor(_ status: DiffReviewStore.FileStatus) -> Color {
        switch status {
        case .added: return .green
        case .modified: return .blue
        case .deleted: return .red
        case .renamed: return .orange
        }
    }

    // MARK: - Hunk View

    private func hunkView(_ hunk: DiffReviewStore.DiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header
            Text(hunk.header)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)

            // Diff lines
            ForEach(hunk.lines) { line in
                diffLineView(line)
            }
        }
    }

    private func diffLineView(_ line: DiffReviewStore.DiffLine) -> some View {
        HStack(spacing: 0) {
            // Line numbers
            Group {
                Text(line.oldLineNumber.map { String($0) } ?? " ")
                    .frame(width: 36, alignment: .trailing)
                Text(line.newLineNumber.map { String($0) } ?? " ")
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.6))

            // Type marker
            Text(linePrefix(line.type))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(lineColor(line.type))
                .frame(width: 14)

            // Content
            Text(line.content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 0.5)
        .background(lineBackground(line.type))
    }

    private func linePrefix(_ type: DiffReviewStore.LineType) -> String {
        switch type {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        }
    }

    private func lineColor(_ type: DiffReviewStore.LineType) -> Color {
        switch type {
        case .context: return .secondary
        case .addition: return .green
        case .deletion: return .red
        }
    }

    private func lineBackground(_ type: DiffReviewStore.LineType) -> Color {
        switch type {
        case .context: return .clear
        case .addition: return .green.opacity(0.15)
        case .deletion: return .red.opacity(0.15)
        }
    }

    // MARK: - Data Loading

    private func loadDiff() async {
        isLoading = true
        defer { isLoading = false }

        let result = await DiffReviewStore.shared.generateDiff(for: session)
        if result == nil {
            errorMessage = "No git diff available for \(session.project)"
        }
        diffResult = result
    }
}
