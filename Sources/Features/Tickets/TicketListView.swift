import SwiftUI

/// Ticket list for a project — grouped by status, sorted by priority.
/// Supports inline status toggling and navigation to detail view.
struct TicketListView: View {
    let project: String
    @ObservedObject private var store = TicketStore.shared
    @State private var selectedTicket: Ticket?
    @State private var showCompleted = false
    @State private var completedTickets: [Ticket] = []

    private var tickets: [Ticket] { store.tickets(for: project) }

    var body: some View {
        Group {
            if tickets.isEmpty && completedTickets.isEmpty {
                emptyState
            } else {
                ticketList
            }
        }
        .onAppear {
            store.refresh()
            completedTickets = store.completedTickets(for: project)
        }
        .sheet(item: $selectedTicket) { ticket in
            TicketDetailView(ticket: ticket)
        }
    }

    // MARK: - List

    private var ticketList: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("\(project) Tickets")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text("\(tickets.count) open")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Grouped sections
            let grouped = Dictionary(grouping: tickets) { $0.status }

            ForEach(statusOrder, id: \.self) { status in
                if let group = grouped[status], !group.isEmpty {
                    statusSection(status: status, tickets: group)
                }
            }

            // Completed section (collapsible)
            if !completedTickets.isEmpty {
                Divider()
                    .padding(.vertical, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCompleted.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.7))
                        Text("COMPLETED")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("(\(completedTickets.count))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if showCompleted {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(completedTickets) { ticket in
                            TicketRowView(ticket: ticket) {
                                selectedTicket = ticket
                            } onStatusChange: { newStatus in
                                store.updateStatus(ticket: ticket, newStatus: newStatus)
                                completedTickets = store.completedTickets(for: project)
                            }
                            .opacity(0.6)
                        }
                    }
                }
            }
        }
    }

    private func statusSection(status: String, tickets: [Ticket]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: sectionIcon(status))
                    .font(.system(size: 9))
                    .foregroundStyle(sectionColor(status))
                Text(status.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("(\(tickets.count))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            ForEach(tickets) { ticket in
                TicketRowView(ticket: ticket) {
                    selectedTicket = ticket
                } onStatusChange: { newStatus in
                    store.updateStatus(ticket: ticket, newStatus: newStatus)
                    completedTickets = store.completedTickets(for: project)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ticket")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No open tickets")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Helpers

    private let statusOrder = ["blocked", "in_progress", "review", "pending"]

    private func sectionIcon(_ status: String) -> String {
        switch status {
        case "blocked": return "exclamationmark.triangle.fill"
        case "in_progress": return "play.circle.fill"
        case "review": return "eye.circle.fill"
        case "pending": return "circle"
        default: return "circle"
        }
    }

    private func sectionColor(_ status: String) -> Color {
        switch status {
        case "blocked": return .red
        case "in_progress": return .blue
        case "review": return .purple
        case "pending": return .secondary
        default: return .secondary
        }
    }
}

// MARK: - Ticket Row

struct TicketRowView: View {
    let ticket: Ticket
    var onTap: () -> Void
    var onStatusChange: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Priority indicator
            Circle()
                .fill(priorityColor)
                .frame(width: 6, height: 6)

            // Ticket ID
            Text(ticket.id)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            // Title
            Text(ticket.title)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Priority badge
            Text(ticket.priority)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(priorityColor)

            // Status toggle menu
            Menu {
                ForEach(["pending", "in_progress", "review", "blocked", "done"], id: \.self) { status in
                    Button(status.replacingOccurrences(of: "_", with: " ").capitalized) {
                        onStatusChange(status)
                    }
                }
            } label: {
                Image(systemName: ticket.statusIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { onTap() }
    }

    private var priorityColor: Color {
        switch ticket.priority {
        case "critical": return .red
        case "high": return .orange
        case "medium": return .yellow
        case "low": return .gray
        default: return .secondary
        }
    }

    private var statusColor: Color {
        switch ticket.status {
        case "done": return .green
        case "in_progress": return .blue
        case "blocked": return .red
        case "review": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Ticket Detail

struct TicketDetailView: View {
    let ticket: Ticket
    @Environment(\.dismiss) private var dismiss
    @State private var linkedFrames: [PenFrameLink] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text(ticket.id)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Priority
                    Text(ticket.priority.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(priorityBackground)
                        .clipShape(Capsule())

                    // Status
                    Text(ticket.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusBackground)
                        .clipShape(Capsule())
                }

                Text(ticket.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                // Description
                if let desc = ticket.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(desc)
                            .font(.system(size: 12))
                    }
                }

                // Acceptance Criteria
                let criteria = ticket.criteriaList
                if !criteria.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Acceptance Criteria")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(criteria, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "circle")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                Text(item)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }

                // Blockers
                let blockerItems = ticket.blockerList
                if !blockerItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blockers")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                        ForEach(blockerItems, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.red)
                                    .padding(.top, 2)
                                Text(item)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }

                // Design Frames
                if !linkedFrames.isEmpty {
                    designFramesSection
                }

                // Metadata
                VStack(alignment: .leading, spacing: 4) {
                    if let assignee = ticket.assignee {
                        metadataRow(label: "Assignee", value: assignee)
                    }
                    if let sprint = ticket.sprint {
                        metadataRow(label: "Sprint", value: sprint)
                    }
                    if let created = ticket.createdAt {
                        metadataRow(label: "Created", value: created)
                    }
                    if let updated = ticket.updatedAt {
                        metadataRow(label: "Updated", value: updated)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 400, minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task { await loadLinkedFrames() }
    }

    // MARK: - Design Frames Section

    private var designFramesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("DESIGN FRAMES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("(\(linkedFrames.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            ForEach(linkedFrames, id: \.id) { link in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.frameName ?? link.frameId)
                            .font(.system(size: 11))
                        if let w = link.width, let h = link.height {
                            Text("\(Int(w)) × \(Int(h))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue.opacity(0.6))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func loadLinkedFrames() async {
        let ticketId = ticket.id
        linkedFrames = await PenAssetStore.shared.frameLinks.filter { $0.ticketId == ticketId }
        if linkedFrames.isEmpty {
            // Also do a live DB query in case store hasn't loaded this project yet
            linkedFrames = await withCheckedContinuation { continuation in
                Task {
                    let result = (try? await PenAssetStore.shared.frameLinksWithTickets(assetId: ""))?.filter { $0.link.ticketId == ticketId }.map { $0.link } ?? []
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 10))
        }
    }

    private var priorityBackground: Color {
        switch ticket.priority {
        case "critical": return .red.opacity(0.2)
        case "high": return .orange.opacity(0.2)
        case "medium": return .yellow.opacity(0.2)
        default: return .gray.opacity(0.2)
        }
    }

    private var statusBackground: Color {
        switch ticket.status {
        case "done": return .green
        case "in_progress": return .blue
        case "blocked": return .red
        case "review": return .purple
        default: return .gray
        }
    }
}
