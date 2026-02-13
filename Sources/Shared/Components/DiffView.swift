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

        var result: [DiffLine] = []

        // Show removed lines
        for line in oldLines {
            result.append(DiffLine(
                prefix: "-",
                text: line,
                color: Color(nsColor: .init(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)),
                background: Color.red.opacity(0.1)
            ))
        }

        // Separator
        if !oldLines.isEmpty && !newLines.isEmpty {
            result.append(DiffLine(
                prefix: " ",
                text: "───",
                color: .secondary.opacity(0.3),
                background: .clear
            ))
        }

        // Show added lines
        for line in newLines {
            result.append(DiffLine(
                prefix: "+",
                text: line,
                color: Color(nsColor: .init(red: 0.4, green: 0.9, blue: 0.4, alpha: 1.0)),
                background: Color.green.opacity(0.08)
            ))
        }

        return result
    }
}
