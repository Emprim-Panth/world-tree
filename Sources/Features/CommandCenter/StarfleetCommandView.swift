import SwiftUI

/// Starfleet Command panel — crew roster, agent status, and recent activity.
struct StarfleetCommandView: View {
    var store = StarfleetStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                crewGrid
                recentActivity
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .onAppear { store.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Starfleet Command")
                    .font(.title2.bold())
                HStack(spacing: 12) {
                    let activeCount = store.crewActivity.values.filter(\.isActive).count
                    statusPill("person.2.fill", "\(StarfleetStore.roster.count) crew", .secondary)
                    if activeCount > 0 {
                        statusPill("bolt.fill", "\(activeCount) active", Palette.success)
                    }
                }
            }
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
        }
    }

    private func statusPill(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
    }

    // MARK: - Crew Grid

    private var crewGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 8)],
            spacing: 8
        ) {
            ForEach(sortedCrew, id: \.id) { member in
                crewCard(member)
            }
        }
    }

    private var sortedCrew: [StarfleetStore.CrewMember] {
        StarfleetStore.roster.map { entry in
            store.crewActivity[entry.name] ?? StarfleetStore.CrewMember(
                id: entry.name, name: entry.name,
                specialization: entry.specialization, icon: entry.icon,
                lastEvent: nil, lastProject: nil, lastSeen: nil, eventCount: 0
            )
        }
    }

    private func crewCard(_ member: StarfleetStore.CrewMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: member.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(member.isActive ? Palette.success : .secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(member.name)
                            .font(.system(size: 11, weight: .semibold))
                        if member.isActive {
                            Circle().fill(Palette.success).frame(width: 6, height: 6)
                        }
                    }
                    Text(member.specialization)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if let project = member.lastProject {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 8))
                        Text(project).font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if member.eventCount > 0 {
                    Text("\(member.eventCount) events")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }

                if let lastSeen = member.lastSeen {
                    Text(lastSeen, style: .relative)
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground.opacity(0.5)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(member.isActive ? Palette.success.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Recent Activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("RECENT ACTIVITY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }

            if store.recentEvents.isEmpty {
                Text("No crew activity recorded yet")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                ForEach(store.recentEvents.prefix(15)) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: StarfleetStore.ActivityEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: eventIcon(event.eventType))
                .font(.system(size: 9))
                .foregroundStyle(eventColor(event.eventType))
                .frame(width: 16)

            Text(event.agentName)
                .font(.system(size: 10, weight: .medium))

            Text(event.eventType)
                .font(.system(size: 9)).foregroundStyle(.secondary)

            if let project = event.project {
                Text(project)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }

            if let detail = event.detail {
                Text(detail)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if let date = event.createdAt {
                Text(date, style: .relative)
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func eventIcon(_ type: String) -> String {
        switch type {
        case "start": return "play.circle.fill"
        case "stop": return "stop.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        case "dispatch": return "paperplane.fill"
        case "complete": return "checkmark.circle.fill"
        case "heartbeat": return "heart.fill"
        default: return "circle.fill"
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "start", "complete": return Palette.success
        case "stop": return Palette.neutral
        case "error": return Palette.error
        case "dispatch": return Palette.cortana
        case "heartbeat": return Palette.info
        default: return .secondary
        }
    }
}
