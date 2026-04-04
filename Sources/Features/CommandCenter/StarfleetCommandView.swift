import SwiftUI

/// Starfleet Command — crew roster displayed as the actual business org structure.
///
/// Source of truth: crew_registry table (v42 migration, seeded from CONSTITUTION.md).
/// Shows the full hierarchy: CEO → CTO → Dept Head → Leads → Workers.
/// Department filter switches role labels between coding and game-dev contexts.
struct StarfleetCommandView: View {
    var store = StarfleetStore.shared
    @State private var selectedDepartment: StarfleetStore.Department = .all

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                departmentPicker
                orgChart
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
                    let total = store.crewRegistry.count
                    let active = store.crewActivity.values.filter(\.isActive).count
                    statusPill("person.2.fill", "\(total) crew", .secondary)
                    if active > 0 {
                        statusPill("bolt.fill", "\(active) active", Palette.success)
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

    // MARK: - Department Picker

    private var departmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(StarfleetStore.Department.allCases, id: \.self) { dept in
                let isSelected = selectedDepartment == dept
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedDepartment = dept
                    }
                } label: {
                    let count = crewCount(for: dept)
                    HStack(spacing: 4) {
                        Text(dept.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        Text("\(count)")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(isSelected ? Palette.cortana.opacity(0.2) : Color.clear))
                            .foregroundStyle(isSelected ? Palette.cortana : .secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Palette.cardBackground : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
            }
            Spacer()
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private func crewCount(for dept: StarfleetStore.Department) -> Int {
        switch dept {
        case .all:     return store.crewRegistry.count
        case .coding:  return store.crewRegistry.filter { $0.department == "coding" || $0.department == "command" }.count
        case .gameDev: return store.crewRegistry.filter { $0.gameDevRole != nil }.count
        }
    }

    // MARK: - Org Chart (grouped by tier — the business structure)

    private var orgChart: some View {
        VStack(spacing: 16) {
            let tiers = tierGroups()
            ForEach(tiers, id: \.tier) { group in
                tierSection(label: group.label, crew: group.crew)
            }
        }
    }

    private struct TierGroup {
        let tier: Int
        let label: String
        let crew: [StarfleetStore.CrewMember]
    }

    private func tierGroups() -> [TierGroup] {
        let filtered = filteredCrew()
        let tiers = Array(Set(filtered.map(\.tier))).sorted()
        return tiers.compactMap { tier in
            let members = filtered.filter { $0.tier == tier }
            guard !members.isEmpty else { return nil }
            return TierGroup(tier: tier, label: tierLabel(tier), crew: members)
        }
    }

    private func filteredCrew() -> [StarfleetStore.CrewMember] {
        switch selectedDepartment {
        case .all:
            return store.crewRegistry
        case .coding:
            return store.crewRegistry.filter {
                $0.department == "coding" || $0.department == "command"
            }
        case .gameDev:
            return store.crewRegistry.filter { $0.gameDevRole != nil }
        }
    }

    private func tierLabel(_ tier: Int) -> String {
        switch tier {
        case 1: return "CTO"
        case 2: return "DEPARTMENT HEAD"
        case 3: return "LEADS"
        case 4: return "WORKERS"
        default: return "TIER \(tier)"
        }
    }

    private func tierSection(label: String, crew: [StarfleetStore.CrewMember]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2, height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.quaternary)
                Text("\(crew.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 8)],
                spacing: 8
            ) {
                ForEach(crew, id: \.id) { member in
                    crewCard(member)
                }
            }
        }
    }

    // MARK: - Crew Card

    private func crewCard(_ member: StarfleetStore.CrewMember) -> some View {
        let activity = store.crewActivity[member.name] ?? member
        let displayRole = member.displayRole(for: selectedDepartment)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: member.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(activity.isActive ? Palette.success : tierAccent(member.tier))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(member.name)
                            .font(.system(size: 11, weight: .semibold))
                        if activity.isActive {
                            Circle().fill(Palette.success).frame(width: 6, height: 6)
                        }
                        Spacer()
                        if member.tier <= 2 {
                            tierBadge(member.tier)
                        }
                    }
                    Text(displayRole)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                if let project = activity.lastProject {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 8))
                        Text(project).font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if activity.eventCount > 0 {
                    Text("\(activity.eventCount) events")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }

                if let lastSeen = activity.lastSeen {
                    Text(lastSeen, style: .relative)
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.cardBackground.opacity(cardOpacity(member.tier)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(cardBorder(member, activity: activity), lineWidth: 1)
        )
    }

    private func tierBadge(_ tier: Int) -> some View {
        Text(tier == 1 ? "CTO" : "HEAD")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Palette.cortana)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Capsule().fill(Palette.cortana.opacity(0.12)))
    }

    private func tierAccent(_ tier: Int) -> Color {
        switch tier {
        case 1: return Palette.cortana
        case 2: return Palette.info
        default: return .secondary
        }
    }

    private func cardOpacity(_ tier: Int) -> Double {
        switch tier {
        case 1: return 0.9
        case 2: return 0.7
        default: return 0.5
        }
    }

    private func cardBorder(_ member: StarfleetStore.CrewMember,
                             activity: StarfleetStore.CrewMember) -> Color {
        if activity.isActive { return Palette.success.opacity(0.3) }
        if member.tier == 1 { return Palette.cortana.opacity(0.2) }
        if member.tier == 2 { return Palette.info.opacity(0.15) }
        return Color.clear
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
        case "start":    return "play.circle.fill"
        case "stop":     return "stop.circle.fill"
        case "error":    return "exclamationmark.triangle.fill"
        case "dispatch": return "paperplane.fill"
        case "complete": return "checkmark.circle.fill"
        case "heartbeat":return "heart.fill"
        default:         return "circle.fill"
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "start", "complete": return Palette.success
        case "stop":              return Palette.neutral
        case "error":             return Palette.error
        case "dispatch":          return Palette.cortana
        case "heartbeat":         return Palette.info
        default:                  return .secondary
        }
    }
}
