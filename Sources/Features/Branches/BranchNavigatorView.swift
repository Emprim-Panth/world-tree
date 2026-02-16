import SwiftUI

/// Mini-map navigator showing branch hierarchy and enabling quick navigation
struct BranchNavigatorView: View {
    let branches: [Branch]
    @Binding var selectedBranchId: String?
    let onSelectBranch: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(branches) { branch in
                    BranchMiniCard(
                        branch: branch,
                        isSelected: selectedBranchId == branch.id
                    )
                    .onTapGesture {
                        selectedBranchId = branch.id
                        onSelectBranch(branch.id)
                    }
                }

                // Add new branch button
                Button(action: { /* TODO: Create root branch */ }) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)

                        Text("New Branch")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 120, height: 60)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundColor(.secondary)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct BranchMiniCard: View {
    let branch: Branch
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Depth indicator
            HStack(spacing: 2) {
                ForEach(0..<branch.depth, id: \.self) { _ in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 4, height: 4)
                }

                if branch.depth > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }

                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }

            Text(branch.title)
                .font(.caption.bold())
                .lineLimit(1)
                .foregroundColor(isSelected ? .blue : .primary)

            HStack(spacing: 4) {
                Text("\(branch.messageCount)")
                    .font(.caption2.monospacedDigit())
                Text("msgs")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(width: 120, height: 60)
        .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    private var statusColor: Color {
        switch branch.status {
        case .active: return .green
        case .completed: return .blue
        case .archived: return .gray
        case .failed: return .red
        }
    }
}

// MARK: - Branch Tree Visualization

struct BranchTreeView: View {
    let branches: [Branch]

    var body: some View {
        Canvas { context, size in
            // Draw branch connections
            drawBranchConnections(
                context: context,
                size: size,
                branches: branches
            )
        }
        .frame(height: 100)
    }

    private func drawBranchConnections(context: GraphicsContext, size: CGSize, branches: [Branch]) {
        let cardWidth: CGFloat = 128
        let spacing: CGFloat = 8

        for (index, branch) in branches.enumerated() {
            let x = CGFloat(index) * (cardWidth + spacing) + cardWidth / 2

            // Draw line to parent
            if let parentId = branch.parentBranchId,
               let parentIndex = branches.firstIndex(where: { $0.id == parentId }) {
                let parentX = CGFloat(parentIndex) * (cardWidth + spacing) + cardWidth / 2

                var path = Path()
                path.move(to: CGPoint(x: parentX, y: size.height / 2))

                // Draw bezier curve
                let controlX = (parentX + x) / 2
                path.addQuadCurve(
                    to: CGPoint(x: x, y: size.height / 2),
                    control: CGPoint(x: controlX, y: size.height * 0.2)
                )

                context.stroke(
                    path,
                    with: .color(.secondary.opacity(0.3)),
                    lineWidth: 2
                )
            }

            // Draw node
            let nodeRect = CGRect(
                x: x - 4,
                y: size.height / 2 - 4,
                width: 8,
                height: 8
            )

            context.fill(
                Path(ellipseIn: nodeRect),
                with: .color(statusColor(branch.status))
            )
        }
    }

    private func statusColor(_ status: Branch.BranchStatus) -> Color {
        switch status {
        case .active: return .green
        case .completed: return .blue
        case .archived: return .gray
        case .failed: return .red
        }
    }
}
