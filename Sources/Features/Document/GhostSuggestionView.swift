import SwiftUI

// MARK: - Compact Chips (primary suggestion UI, shown below the input field)

/// Compact horizontal chips that appear below the text input when branching is detected.
/// Much less intrusive than the full GhostSuggestionView — stays below the input, never pushes it up.
struct BranchSuggestionChips: View {
    let suggestions: [BranchSuggestion]
    let selectedIndex: Int
    let onAccept: (BranchSuggestion) -> Void
    let onAcceptAll: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                Text("Branch detected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button(action: { onAccept(suggestion) }) {
                            Text(suggestion.title)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(index == selectedIndex
                                    ? Color.blue.opacity(0.15)
                                    : Color(nsColor: .controlBackgroundColor))
                                .foregroundStyle(index == selectedIndex ? Color.blue : Color.primary)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(index == selectedIndex
                                            ? Color.blue.opacity(0.4)
                                            : Color(nsColor: .separatorColor).opacity(0.5),
                                            lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(suggestion.preview)
                    }

                    if suggestions.count > 1 {
                        Button(action: onAcceptAll) {
                            Label("All in parallel", systemImage: "square.split.2x1")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.1))
                                .foregroundStyle(.orange)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Spawn all branches in parallel (⌘↵)")
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.15), value: selectedIndex)
    }
}

// MARK: - Full Card (kept for reference, no longer shown in main UI)

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
