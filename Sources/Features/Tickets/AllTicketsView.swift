import SwiftUI

/// All tickets across all projects — the global ticket dashboard.
/// Accessed from the sidebar "Tickets" button.
struct AllTicketsView: View {
    @ObservedObject private var store = TicketStore.shared
    @State private var selectedTicket: Ticket?
    @State private var showCompleted = false
    @State private var completedByProject: [(String, [Ticket])] = []

    private var projectsWithTickets: [(String, [Ticket])] {
        store.tickets
            .filter { !$0.value.isEmpty }
            .sorted { a, b in
                // Projects with blocked tickets first, then by count
                let aBlocked = a.value.filter(\.isBlocked).count
                let bBlocked = b.value.filter(\.isBlocked).count
                if aBlocked != bBlocked { return aBlocked > bBlocked }
                return a.value.count > b.value.count
            }
    }

    private var totalCount: Int { store.tickets.values.flatMap { $0 }.count }
    private var blockedCount: Int { store.tickets.values.flatMap { $0 }.filter(\.isBlocked).count }
    private var completedCount: Int { completedByProject.flatMap { $0.1 }.count }

    private func loadCompleted() {
        completedByProject = store.allCompletedTickets()
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tickets")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                if blockedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("\(blockedCount) blocked")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.1))
                    .clipShape(Capsule())
                }

                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10))
                    Text("\(totalCount) open")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)

                Button {
                    store.scanAll()
                    store.refresh()
                    loadCompleted()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if projectsWithTickets.isEmpty && completedByProject.isEmpty {
                ContentUnavailableView(
                    "No Tickets",
                    systemImage: "checkmark.circle",
                    description: Text("No tickets across any project.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(projectsWithTickets, id: \.0) { project, tickets in
                            projectSection(project: project, tickets: tickets)
                        }

                        // Completed section
                        if !completedByProject.isEmpty {
                            VStack(spacing: 0) {
                                Button {
                                    showCompleted.toggle()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("Completed")
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("(\(completedCount))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)

                                if showCompleted {
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        ForEach(completedByProject, id: \.0) { project, tickets in
                                            completedProjectSection(project: project, tickets: tickets)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            store.scanAll()
            store.refresh()
            loadCompleted()
        }
        .sheet(item: $selectedTicket) { ticket in
            TicketDetailView(ticket: ticket)
        }
    }

    private func completedProjectSection(project: String, tickets: [Ticket]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(tickets.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(tickets) { ticket in
                TicketRowView(ticket: ticket) {
                    selectedTicket = ticket
                } onStatusChange: { newStatus in
                    store.updateStatus(ticket: ticket, newStatus: newStatus)
                    loadCompleted()
                }
                .opacity(0.6)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func projectSection(project: String, tickets: [Ticket]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Project header
            HStack(spacing: 8) {
                Text(project)
                    .font(.system(size: 13, weight: .semibold))

                let blocked = tickets.filter(\.isBlocked).count
                if blocked > 0 {
                    Text("\(blocked) blocked")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Capsule())
                }

                Spacer()

                Text("\(tickets.count) open")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Ticket rows
            let grouped = Dictionary(grouping: tickets) { $0.status }
            let statusOrder = ["blocked", "in_progress", "review", "pending"]

            ForEach(statusOrder, id: \.self) { status in
                if let group = grouped[status], !group.isEmpty {
                    ForEach(group) { ticket in
                        TicketRowView(ticket: ticket) {
                            selectedTicket = ticket
                        } onStatusChange: { newStatus in
                            store.updateStatus(ticket: ticket, newStatus: newStatus)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
