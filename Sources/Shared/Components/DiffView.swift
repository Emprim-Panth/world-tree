import SwiftUI

/// Renders a side-by-side or unified diff of old vs new text
struct DiffView: View {
    let oldText: String
    let newText: String
    let filePath: String?

    init(oldText: String, newText: String, filePath: String? = nil) {
        self.oldText = oldText
        self.newText = newText
        self.filePath = filePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let filePath {
                    Text(URL(fileURLWithPath: filePath).lastPathComponent)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                Text("edit")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05))

            // Diff content
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.prefix)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.color.opacity(0.7))
                                .frame(width: 16, alignment: .center)

                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.color)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.background)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .init(white: 0.12, alpha: 1.0)))
        .cornerRadius(6)
    }

    // MARK: - Diff Computation

    private struct DiffLine {
        let prefix: String
        let text: String
        let color: Color
        let background: Color
    }

    private var diffLines: [DiffLine] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")

        // Use Swift's CollectionDifference for a proper LCS-based unified diff
        let diff = newLines.difference(from: oldLines)

        // Build a map of changed indices for interleaving
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var result: [DiffLine] = []

        // Walk both arrays in tandem, interleaving changes
        var oldIdx = 0
        var newIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            let oldRemoved = oldIdx < oldLines.count && removedOffsets.contains(oldIdx)
            let newInserted = newIdx < newLines.count && insertedOffsets.contains(newIdx)

            if oldIdx < oldLines.count && oldRemoved {
                result.append(DiffLine(
                    prefix: "-",
                    text: oldLines[oldIdx],
                    color: Color(nsColor: .init(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)),
                    background: Color.red.opacity(0.1)
                ))
                oldIdx += 1
            } else if newIdx < newLines.count && newInserted {
                result.append(DiffLine(
                    prefix: "+",
                    text: newLines[newIdx],
                    color: Color(nsColor: .init(red: 0.4, green: 0.9, blue: 0.4, alpha: 1.0)),
                    background: Color.green.opacity(0.08)
                ))
                newIdx += 1
            } else {
                // Context line — present in both
                if oldIdx < oldLines.count {
                    result.append(DiffLine(
                        prefix: " ",
                        text: oldLines[oldIdx],
                        color: Color.primary.opacity(0.6),
                        background: .clear
                    ))
                    oldIdx += 1
                    newIdx += 1
                } else {
                    break
                }
            }
        }

        return result
    }
}
