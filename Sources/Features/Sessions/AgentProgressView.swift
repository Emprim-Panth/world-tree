import SwiftUI

/// Overlay for dispatch sessions showing agent progress indicators.
struct AgentProgressView: View {
    let session: SessionManager.ManagedSession
    var hookRouter = HookRouter.shared

    private var events: [HookRouter.HookEvent] {
        hookRouter.events(for: session.claudeSessionID)
    }

    private var toolUseCount: Int {
        events.filter { $0.hookType == "PostToolUse" }.count
    }

    private var filesChanged: Set<String> {
        Set(events.compactMap { event -> String? in
            guard let payload = event.payload,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = json["file_path"] as? String else { return nil }
            return (path as NSString).lastPathComponent
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .foregroundStyle(session.state == .running ? Palette.success : Palette.neutral)
                Text("Agent Dispatch")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(session.createdAt, style: .relative)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            HStack(spacing: 16) {
                statBadge("Tools", "\(toolUseCount)", Palette.info)
                statBadge("Files", "\(filesChanged.count)", Palette.warning)
                statBadge("Status", session.state.rawValue.capitalized,
                          session.state == .running ? Palette.success : Palette.neutral)
            }

            if !filesChanged.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Modified files:").font(.system(size: 8)).foregroundStyle(.tertiary)
                    ForEach(Array(filesChanged).sorted().prefix(5), id: \.self) { file in
                        Text("  \(file)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.cortana.opacity(0.3)))
    }

    private func statBadge(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(color)
            Text(label).font(.system(size: 7)).foregroundStyle(.tertiary)
        }
    }
}
