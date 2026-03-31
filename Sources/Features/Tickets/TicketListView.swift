import SwiftUI

/// Ticket list for a project — grouped by status, sorted by priority.
/// Supports inline status toggling and navigation to detail view.
struct TicketListView: View {
    let project: String
    var store = TicketStore.shared
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
        .onChange(of: store.tickets) { _ in
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

    private func statusSection(status: TicketStatus, tickets: [Ticket]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: sectionIcon(status))
                    .font(.system(size: 9))
                    .foregroundStyle(sectionColor(status))
                Text(status.rawValue.replacingOccurrences(of: "_", with: " ").uppercased())
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

    private let statusOrder: [TicketStatus] = [.blocked, .inProgress, .review, .pending]

    private func sectionIcon(_ status: TicketStatus) -> String {
        switch status {
        case .blocked: return "exclamationmark.triangle.fill"
        case .inProgress: return "play.circle.fill"
        case .review: return "eye.circle.fill"
        case .pending: return "circle"
        default: return "circle"
        }
    }

    private func sectionColor(_ status: TicketStatus) -> Color {
        switch status {
        case .blocked: return .red
        case .inProgress: return .blue
        case .review: return .purple
        case .pending: return .secondary
        default: return .secondary
        }
    }
}

// MARK: - Ticket Row

struct TicketRowView: View {
    let ticket: Ticket
    var onTap: () -> Void
    var onStatusChange: (TicketStatus) -> Void

    private static let menuStatuses: [TicketStatus] = [.pending, .inProgress, .review, .blocked, .done]

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
                ForEach(Self.menuStatuses, id: \.self) { status in
                    Button(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) {
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
        .background(Palette.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { onTap() }
    }

    private var priorityColor: Color { Palette.forPriority(ticket.priority) }
    private var statusColor: Color { Palette.forStatus(ticket.status) }
}

// MARK: - Ticket Detail

struct TicketDetailView: View {
    let ticket: Ticket
    @Environment(\.dismiss) private var dismiss

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
                    Text(ticket.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
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
        case .done: return .green
        case .inProgress: return .blue
        case .blocked: return .red
        case .review: return .purple
        default: return .gray
        }
    }
}
