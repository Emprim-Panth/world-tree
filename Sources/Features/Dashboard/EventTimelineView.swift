import SwiftUI

/// Date range presets for timeline filtering.
enum TimelineRange: String, CaseIterable {
    case week = "7 Days"
    case month = "30 Days"
    case all = "All Time"

    var since: Date? {
        switch self {
        case .week:  return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .all:   return nil
        }
    }
}

/// Unified timeline showing events from all Cortana systems.
struct EventTimelineView: View {
    @State private var events: [UnifiedTimelineEvent] = []
    @State private var isLoading = false
    @State private var selectedTypes: Set<UnifiedTimelineEvent.EventType> = Set(UnifiedTimelineEvent.EventType.allCases)
    @State private var projectFilter: String = ""
    @State private var selectedRange: TimelineRange = .month

    var body: some View {
        VStack(spacing: 0) {
            // Filters
            HStack {
                Text("Timeline")
                    .font(.headline)

                // Date range picker
                Picker("Range", selection: $selectedRange) {
                    ForEach(TimelineRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: selectedRange) { _, _ in
                    Task { await loadEvents() }
                }

                Spacer()

                // Event type filter chips
                ForEach(UnifiedTimelineEvent.EventType.allCases, id: \.self) { type in
                    Button {
                        if selectedTypes.contains(type) {
                            selectedTypes.remove(type)
                        } else {
                            selectedTypes.insert(type)
                        }
                        Task { await loadEvents() }
                    } label: {
                        Label(type.label, systemImage: type.icon)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedTypes.contains(type) ? .accentColor : .secondary)
                }

                Button {
                    Task { await loadEvents() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh timeline")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                ProgressView("Loading timeline...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "clock",
                    description: Text("No timeline events found for the selected filters.")
                )
            } else {
                List(events) { event in
                    TimelineEventRow(event: event)
                }
                .listStyle(.inset)
            }
        }
        .task { await loadEvents() }
    }

    private func loadEvents() async {
        isLoading = true
        defer { isLoading = false }

        let types = selectedTypes.isEmpty ? nil : selectedTypes
        let project = projectFilter.isEmpty ? nil : projectFilter

        do {
            events = try await TimelineStore.shared.getTimeline(
                project: project,
                eventTypes: types,
                since: selectedRange.since,
                limit: 100
            )
        } catch {
            wtLog("[Timeline] Failed to load: \(error)")
        }
    }
}

struct TimelineEventRow: View {
    let event: UnifiedTimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.eventType.icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.eventType.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if let project = event.project {
                        Text(project)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Text(event.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(event.summary)
                    .font(.callout)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch event.eventType {
        case .session: return .blue
        case .dispatch: return .orange
        case .knowledgeAdd: return .purple
        case .knowledgeUpdate: return .indigo
        case .archival: return .green
        case .crewDispatch: return .teal
        case .graphChange: return .pink
        }
    }
}
