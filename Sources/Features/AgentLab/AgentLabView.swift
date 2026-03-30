import SwiftUI

struct AgentLabView: View {
    @State private var viewModel = AgentLabViewModel()
    @State private var selectedSession: AgentLabViewModel.AgentSession?
    @State private var selectedTab: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            HStack {
                Picker("", selection: $selectedTab) {
                    Text("Live").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Spacer()

                if viewModel.activeSession != nil {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.green.opacity(0.4), lineWidth: 2))
                        .padding(.trailing, 16)
                }
            }
            .background(Palette.windowBackground)

            Divider()

            if selectedTab == 0 {
                liveTab
            } else {
                historyTab
            }
        }
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
        .sheet(item: $selectedSession) { session in
            ProofDetailView(session: session)
        }
    }

    // MARK: - Live Tab

    @ViewBuilder
    private var liveTab: some View {
        if let session = viewModel.activeSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Session header
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(session.project)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            if !session.elapsedText.isEmpty {
                                Text(session.elapsedText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Palette.cardBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Text(session.displayTask)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(16)
                    .background(Palette.cardBackground.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Live screenshot
                    if let imageData = viewModel.liveScreenshotData,
                       let nsImage = NSImage(data: imageData) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Latest Screenshot")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }
                    }

                    // Activity indicator
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Watching for activity...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .padding(16)
            }
        } else {
            liveEmptyState
        }
    }

    private var liveEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No active agent session")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Agent sessions appear here when cortana-dispatch is running a task.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - History Tab

    @ViewBuilder
    private var historyTab: some View {
        if viewModel.sessions.isEmpty {
            historyEmptyState
        } else {
            List(viewModel.sessions) { session in
                SessionRowView(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedSession = session }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
        }
    }

    private var historyEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No completed sessions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let session: AgentLabViewModel.AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Text(session.buildStatusEmoji)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.project)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(session.relativeTimestamp)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(session.displayTask.prefix(60) + (session.displayTask.count > 60 ? "…" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
