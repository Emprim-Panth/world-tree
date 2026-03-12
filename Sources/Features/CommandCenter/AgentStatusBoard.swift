import SwiftUI

/// Grid-based overview of all agent sessions — active first, recent completed collapsed below.
/// Returns EmptyView when there's nothing to show.
struct AgentStatusBoard: View {
    @ObservedObject var store: AgentStatusStore = .shared

    @State private var showRecent = false

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 8)
    ]

    var body: some View {
        if store.activeSessions.isEmpty && store.recentCompleted.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader
                activeGrid
                recentSection
            }
        }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text("AGENTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            if store.totalActiveCount > 0 {
                Text("\(store.totalActiveCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.green))
            }

            Spacer()
        }
    }

    // MARK: - Active Grid

    @ViewBuilder
    private var activeGrid: some View {
        if !store.activeSessions.isEmpty {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.activeSessions, id: \.id) { session in
                    AgentStatusCard(session: session, health: store.healthScores[session.id])
                }
            }
        }
    }

    // MARK: - Recent Completed

    @ViewBuilder
    private var recentSection: some View {
        let recent = Array(store.recentCompleted.prefix(5))
        if !recent.isEmpty {
            DisclosureGroup(isExpanded: $showRecent) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(recent, id: \.id) { session in
                        AgentStatusCard(session: session)
                            .opacity(0.7)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text("Recent")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(.automatic)
        }
    }
}
