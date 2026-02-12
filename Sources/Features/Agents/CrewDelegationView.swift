import SwiftUI

// MARK: - Crew Delegation Chain

/// Shows which crew members / tools have been active on a branch.
/// Inferred from event data — tool names map to crew roles.
struct CrewDelegationView: View {
    let branchId: String
    @State private var delegations: [CrewDelegation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.cyan)
                Text("Crew Activity")
                    .font(.headline)
                Spacer()
            }

            if delegations.isEmpty {
                Text("No crew activity recorded")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(delegations) { delegation in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(delegation.color)
                            .frame(width: 8, height: 8)

                        Text(delegation.crewMember)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)

                        Text(delegation.domain)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("\(delegation.actionCount) actions")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .onAppear { loadDelegations() }
    }

    private func loadDelegations() {
        let counts = EventStore.shared.eventCounts(branchId: branchId)
        var results: [CrewDelegation] = []

        // Map tool events to crew members
        let toolEvents = EventStore.shared.toolEvents(branchId: branchId)
        var toolCounts: [String: Int] = [:]
        for event in toolEvents where event.eventType == .toolStart {
            if let data = event.eventData,
               let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
               let name = json["name"] as? String {
                toolCounts[name, default: 0] += 1
            }
        }

        // Infer crew from tool usage
        for (tool, count) in toolCounts {
            let (crew, domain, color) = crewForTool(tool)
            if let existing = results.firstIndex(where: { $0.crewMember == crew }) {
                results[existing].actionCount += count
            } else {
                results.append(CrewDelegation(
                    crewMember: crew, domain: domain,
                    actionCount: count, color: color
                ))
            }
        }

        // Add general assistant activity
        let textEvents = (counts[.messageAssistant] ?? 0) + (counts[.textChunk] ?? 0) / 10
        if textEvents > 0 {
            results.append(CrewDelegation(
                crewMember: "Cortana", domain: "First Officer",
                actionCount: textEvents, color: .cyan
            ))
        }

        delegations = results.sorted { $0.actionCount > $1.actionCount }
    }

    private func crewForTool(_ tool: String) -> (String, String, Color) {
        switch tool {
        case "read_file", "glob", "grep", "list_files":
            return ("Geordi", "Architecture", .orange)
        case "edit_file", "write_file":
            return ("Scotty", "Implementation", .green)
        case "bash":
            return ("O'Brien", "Operations", .yellow)
        case "search", "web_search":
            return ("Seven", "Research", .purple)
        default:
            return ("Data", "Analysis", .blue)
        }
    }
}

struct CrewDelegation: Identifiable {
    let id = UUID()
    let crewMember: String
    let domain: String
    var actionCount: Int
    let color: Color
}
