import SwiftUI

struct MessageRow: View {
    let message: Message
    let onFork: (Message, BranchType) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Role label
                HStack(spacing: 4) {
                    if message.role == .assistant {
                        Image(systemName: "diamond.fill")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                    Text(roleName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if message.hasBranches {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Content
                if message.role == .system {
                    systemMessageContent
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(bubbleBackground)
                        .cornerRadius(12)
                }

                // Fork button on hover
                if isHovering && message.role != .system {
                    forkButtons
                }
            }
            .frame(maxWidth: 600, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant || message.role == .system {
                Spacer(minLength: 80)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Branch from here") {
                onFork(message, .conversation)
            }
            Button("Implementation branch") {
                onFork(message, .implementation)
            }
            Button("Exploration branch") {
                onFork(message, .exploration)
            }
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }
        }
    }

    private var roleName: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Cortana"
        case .system: "System"
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: .blue.opacity(0.2)
        case .assistant: .primary.opacity(0.08)
        case .system: .clear
        }
    }

    private var systemMessageContent: some View {
        Text(message.content)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.quaternary)
            .cornerRadius(8)
    }

    private var forkButtons: some View {
        HStack(spacing: 8) {
            Button {
                onFork(message, .conversation)
            } label: {
                Label("Branch", systemImage: "arrow.triangle.branch")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
