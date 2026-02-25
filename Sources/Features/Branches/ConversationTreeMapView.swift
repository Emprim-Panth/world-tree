import SwiftUI

// MARK: - Private Data Types

private struct TMBranchData: Identifiable {
    let id: String
    let branch: Branch
    var nodes: [TMNodeData]
}

private struct TMNodeData: Identifiable {
    let id: String
    let role: MessageRole
    let preview: String
    let timestamp: Date
    var childBranches: [TMBranchData]
}

// MARK: - Main View

struct ConversationTreeMapView: View {
    let treeId: String
    let currentBranchId: String
    let onNavigate: (String) -> Void

    @State private var rootData: TMBranchData?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                Spacer()
                ProgressView("Building tree…")
                Spacer()
            } else if let root = rootData {
                ScrollView([.vertical, .horizontal]) {
                    TMBranchColumnView(
                        branch: root,
                        depth: 0,
                        currentBranchId: currentBranchId,
                        onNavigate: { branchId in
                            onNavigate(branchId)
                            dismiss()
                        }
                    )
                    .padding(24)
                }
            } else {
                Spacer()
                Text("No conversation data yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(minWidth: 500, idealWidth: 720, maxWidth: 1100,
               minHeight: 380, idealHeight: 580)
        .onAppear { loadTree() }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.blue)
            Text("Conversation Tree")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func loadTree() {
        Task { @MainActor in
            guard let tree = try? TreeStore.shared.getTree(treeId),
                  let root = tree.rootBranch else {
                isLoading = false
                return
            }
            rootData = buildBranchData(root, allBranches: tree.branches)
            isLoading = false
        }
    }

    @MainActor
    private func buildBranchData(_ branch: Branch, allBranches: [Branch]) -> TMBranchData {
        let sessionId = branch.sessionId ?? ""
        let messages = (try? MessageStore.shared.getMessages(sessionId: sessionId, limit: 150)) ?? []
        let children = allBranches.filter { $0.parentBranchId == branch.id }

        var nodes: [TMNodeData] = []
        for msg in messages {
            let forkBranches = children.filter { $0.forkFromMessageId == msg.id }
            let childBranches = forkBranches.map { buildBranchData($0, allBranches: allBranches) }

            let preview = msg.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")

            nodes.append(TMNodeData(
                id: msg.id,
                role: msg.role,
                preview: String(preview.prefix(90)),
                timestamp: msg.createdAt,
                childBranches: childBranches
            ))
        }

        return TMBranchData(id: branch.id, branch: branch, nodes: nodes)
    }
}

// MARK: - Branch Column

private struct TMBranchColumnView: View {
    let branch: TMBranchData
    let depth: Int
    let currentBranchId: String
    let onNavigate: (String) -> Void

    private let nodeWidth: CGFloat = 310

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if depth > 0 {
                branchHeader
                    .padding(.bottom, 8)
            }

            ForEach(Array(branch.nodes.enumerated()), id: \.element.id) { idx, node in
                TMMessageNodeView(
                    node: node,
                    isActive: branch.id == currentBranchId,
                    onTap: { onNavigate(branch.id) }
                )
                .frame(width: nodeWidth)

                // Connector down to next node or branch fork
                let hasNext = idx < branch.nodes.count - 1
                let hasForks = !node.childBranches.isEmpty

                if hasNext || hasForks {
                    connector
                }

                // Branch forks expand below their trigger message
                if hasForks {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(node.childBranches) { child in
                            TMBranchColumnView(
                                branch: child,
                                depth: depth + 1,
                                currentBranchId: currentBranchId,
                                onNavigate: onNavigate
                            )
                        }
                    }
                    .padding(.leading, 28)

                    if hasNext {
                        connector
                    }
                }
            }
        }
        .padding(depth > 0 ? 12 : 0)
        .background(depth > 0 ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: depth > 0 ? 10 : 0))
        .overlay {
            if depth > 0 {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .shadow(color: depth > 0 ? .black.opacity(0.06) : .clear, radius: 4, y: 2)
    }

    private var branchHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(.blue)
            Text(branch.branch.displayTitle)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(branch.nodes.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Thin vertical line connecting nodes
    private var connector: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 2, height: 14)
            .padding(.leading, 12) // center on 26pt avatar
    }
}

// MARK: - Message Node

private struct TMMessageNodeView: View {
    let node: TMNodeData
    let isActive: Bool
    let onTap: () -> Void

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var roleColor: Color { node.role == .user ? .blue : .purple }
    private var roleLabel: String { node.role == .user ? "E" : "C" }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // Role avatar
            ZStack {
                Circle()
                    .fill(roleColor.opacity(0.14))
                    .frame(width: 26, height: 26)
                Text(roleLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(roleColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(node.preview.isEmpty ? "(empty)" : node.preview)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(Self.timeFmt.string(from: node.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !node.childBranches.isEmpty {
                        Label(
                            "\(node.childBranches.count) branch\(node.childBranches.count == 1 ? "" : "es")",
                            systemImage: "arrow.triangle.branch"
                        )
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive
                      ? Color.accentColor.opacity(0.08)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
