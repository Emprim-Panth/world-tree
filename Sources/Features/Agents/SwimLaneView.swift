import SwiftUI

// MARK: - Swim Lane Visualization

/// Visual lanes per crew member / agent showing activity over time.
/// Each lane displays tool executions and text outputs as colored blocks.
struct SwimLaneView: View {
    let branchId: String
    @State private var events: [CanvasEvent] = []
    @State private var agents: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.horizontal.page")
                    .foregroundStyle(.cyan)
                Text("Activity Swim Lanes")
                    .font(.headline)
                Spacer()
                Button("Refresh") { loadEvents() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding()

            if events.isEmpty {
                Text("No activity recorded yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(agents, id: \.self) { agent in
                            AgentLane(
                                agentName: agent,
                                events: events.filter { extractAgent(from: $0) == agent }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear { loadEvents() }
    }

    private func loadEvents() {
        events = EventStore.shared.recentEvents(branchId: branchId, limit: 200)
        // Extract unique agent names from events
        var seen = Set<String>()
        agents = events.compactMap { extractAgent(from: $0) }.filter { seen.insert($0).inserted }
        if agents.isEmpty {
            agents = ["Primary"]
        }
    }

    private func extractAgent(from event: CanvasEvent) -> String {
        guard let data = event.eventData,
              let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let agent = json["agent"] as? String else {
            return "Primary"
        }
        return agent
    }
}

// MARK: - Agent Lane

/// Single horizontal lane showing activity blocks for one agent.
struct AgentLane: View {
    let agentName: String
    let events: [CanvasEvent]

    var body: some View {
        HStack(spacing: 0) {
            // Agent label
            Text(agentName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 8)

            // Event blocks
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        eventBlock(for: event)
                    }
                }
            }
        }
        .frame(height: 24)
    }

    private func eventBlock(for event: CanvasEvent) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(colorForEvent(event))
            .frame(width: blockWidth(for: event), height: 16)
            .help("\(event.eventType.rawValue) at \(event.timestamp.formatted(date: .omitted, time: .shortened))")
    }

    private func colorForEvent(_ event: CanvasEvent) -> Color {
        switch event.eventType {
        case .textChunk: return .cyan.opacity(0.6)
        case .toolStart: return .orange.opacity(0.8)
        case .toolEnd: return .green.opacity(0.7)
        case .toolError: return .red.opacity(0.8)
        case .messageUser: return .blue.opacity(0.6)
        case .messageAssistant: return .purple.opacity(0.6)
        case .error: return .red
        default: return .gray.opacity(0.3)
        }
    }

    private func blockWidth(for event: CanvasEvent) -> CGFloat {
        switch event.eventType {
        case .toolStart, .toolEnd, .toolError: return 12
        case .textChunk: return 4
        default: return 8
        }
    }
}
