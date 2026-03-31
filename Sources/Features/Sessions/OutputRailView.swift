import SwiftUI

/// Output rail showing structured PostToolUse results for a session.
struct OutputRailView: View {
    let sessionID: String
    var hookRouter = HookRouter.shared

    var body: some View {
        let events = hookRouter.events(for: sessionID)
            .filter { $0.hookType == "PostToolUse" }
            .suffix(10)

        if events.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(events)) { event in
                        toolBadge(event)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Palette.cardBackground.opacity(0.5))
        }
    }

    private func toolBadge(_ event: HookRouter.HookEvent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: toolIcon(event.toolName ?? ""))
                .font(.system(size: 8))
            Text(event.toolName ?? "Tool")
                .font(.system(size: 9, weight: .medium))
            if let date = event.createdAt {
                Text(date, style: .relative)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Palette.cardBackground)
        .clipShape(Capsule())
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Read": return "doc.text"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.magnifyingglass"
        case "Agent": return "person.2"
        default: return "wrench"
        }
    }
}
