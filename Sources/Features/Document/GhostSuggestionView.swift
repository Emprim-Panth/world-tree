import SwiftUI

/// Ghost text suggestions that appear as you type
struct GhostSuggestionView: View {
    let suggestions: [BranchSuggestion]
    let selectedIndex: Int
    let onAccept: (BranchSuggestion) -> Void
    let onAcceptAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundColor(.blue)

                Text("Branch suggestions")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Tab to accept • ⌘↵ for all")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.05))

            // Suggestions
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                GhostSuggestionRow(
                    suggestion: suggestion,
                    isSelected: index == selectedIndex,
                    shortcut: index == 0 ? "Tab" : nil,
                    onTap: { onAccept(suggestion) }
                )
            }

            // Accept all button (if multiple suggestions)
            if suggestions.count > 1 {
                Button(action: onAcceptAll) {
                    HStack {
                        Image(systemName: "square.split.2x1")
                        Text("Explore all \(suggestions.count) in parallel")
                        Spacer()
                        Text("⌘↵")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}

struct GhostSuggestionRow: View {
    let suggestion: BranchSuggestion
    let isSelected: Bool
    let shortcut: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Selection indicator
                Circle()
                    .fill(isSelected ? Color.blue : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(suggestion.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(isSelected ? .primary : .secondary)

                        Spacer()

                        if let shortcut = shortcut {
                            Text(shortcut)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }

                    Text(suggestion.preview)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(2)

                    // Confidence indicator
                    HStack(spacing: 4) {
                        ForEach(0..<5) { i in
                            Circle()
                                .fill(i < Int(suggestion.confidence * 5) ? Color.blue : Color.secondary.opacity(0.2))
                                .frame(width: 4, height: 4)
                        }
                        Text("\(Int(suggestion.confidence * 100))% confidence")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.05) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
