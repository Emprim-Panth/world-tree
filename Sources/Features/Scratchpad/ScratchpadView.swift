import SwiftUI

/// Live scratchpad feed showing agent findings, decisions, blockers, and handoffs
/// across all projects. Filter by project or type.
struct ScratchpadView: View {
    @State private var store = ScratchpadStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()

            if store.entries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: — Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scratchpad")
                    .font(.title2.bold())
                Text("\(store.activeCount) active entries across \(store.projects.count) projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let lastUpdate = store.lastUpdate {
                Text("Updated \(lastUpdate, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    // MARK: — Filters

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Project filter
            Picker("Project", selection: Binding(
                get: { store.filterProject ?? "" },
                set: { store.filterProject = $0.isEmpty ? nil : $0; store.refresh() }
            )) {
                Text("All Projects").tag("")
                ForEach(allProjects, id: \.self) { project in
                    Text(project).tag(project)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)

            // Type filter
            Picker("Type", selection: Binding(
                get: { store.filterType ?? "" },
                set: { store.filterType = $0.isEmpty ? nil : $0; store.refresh() }
            )) {
                Text("All Types").tag("")
                Label("Finding", systemImage: "magnifyingglass").tag("finding")
                Label("Decision", systemImage: "diamond.fill").tag("decision")
                Label("Blocker", systemImage: "exclamationmark.octagon.fill").tag("blocker")
                Label("Handoff", systemImage: "arrow.right.circle.fill").tag("handoff")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 150)

            Spacer()

            // Type counts
            HStack(spacing: 8) {
                if let findings = store.byType["finding"] {
                    typeBadge("F", count: findings, color: Palette.info)
                }
                if let decisions = store.byType["decision"] {
                    typeBadge("D", count: decisions, color: Palette.accent)
                }
                if let blockers = store.byType["blocker"] {
                    typeBadge("B", count: blockers, color: Palette.error)
                }
                if let handoffs = store.byType["handoff"] {
                    typeBadge("H", count: handoffs, color: Palette.warning)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func typeBadge(_ letter: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(letter).font(.caption2.bold())
            Text("\(count)").font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    /// All projects from unfiltered data
    private var allProjects: [String] {
        // Read from DB without filter to get full project list
        Array(Set(store.entries.map(\.project))).sorted()
    }

    // MARK: — Entry List

    private var entryList: some View {
        List(store.entries) { entry in
            entryRow(entry)
        }
        .listStyle(.inset)
    }

    private func entryRow(_ entry: ScratchpadEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: entry.typeIcon)
                    .foregroundStyle(colorForType(entry.entryType))
                    .font(.caption)

                Text(entry.entryType.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(colorForType(entry.entryType))

                Text(entry.project)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Palette.accent.opacity(0.1))
                    .clipShape(Capsule())

                Text("/ \(entry.topic)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(entry.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(entry.content)
                .font(.body)
                .lineLimit(4)

            HStack {
                Text(entry.agent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if !entry.sessionId.isEmpty {
                    Text("session: \(entry.sessionId.prefix(8))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: — Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("No scratchpad entries")
                .font(.title3)
            Text("Agents write here during work — findings, decisions, blockers, handoffs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: — Helpers

    private func colorForType(_ type: String) -> Color {
        switch type {
        case "finding": return Palette.info
        case "decision": return Palette.accent
        case "blocker": return Palette.error
        case "handoff": return Palette.warning
        default: return Palette.neutral
        }
    }
}
