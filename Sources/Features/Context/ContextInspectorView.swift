import SwiftUI

// MARK: - Context Inspector View (model lives in ContextProvenanceStore.swift)

/// Popover that shows exactly what context was injected on the most recent send.
/// Blocks — gameplan, recent messages, checkpoint, scored history, memory, project context
/// — each show token estimate and expandable raw content so the user can see why Cortana
/// knows (or doesn't know) something.
struct ContextInspectorView: View {
    let provenance: ContextProvenance
    @State private var expandedId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(provenance.blocks) { block in
                        blockRow(block)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 380, height: 420)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Injected")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Label(provenance.model, systemImage: "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    let approxTokens = provenance.totalChars / 4
                    Text("~\(approxTokens) tokens")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(approxTokens > 8000 ? .orange : .secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(provenance.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func blockRow(_ block: ContextProvenance.Block) -> some View {
        let isExpanded = expandedId == block.id
        let approxTokens = block.charCount / 4

        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard block.wasInjected else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedId = isExpanded ? nil : block.id
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: block.icon)
                        .font(.system(size: 11))
                        .frame(width: 16)
                        .foregroundStyle(block.wasInjected ? .primary : .tertiary)

                    Text(block.label)
                        .font(.system(size: 12))
                        .foregroundStyle(block.wasInjected ? .primary : .secondary)

                    Spacer()

                    if block.wasInjected {
                        Text("~\(approxTokens) tok")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(Capsule())

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("empty")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isExpanded ? Color.primary.opacity(0.05) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if isExpanded && block.wasInjected {
                Text(block.content.prefix(2000))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
