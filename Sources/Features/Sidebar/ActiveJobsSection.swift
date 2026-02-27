import SwiftUI
import GRDB

// MARK: - Processing Banner (Option B)

/// Shows a subtle "Cortana working…" strip when any branch is processing.
/// Visible regardless of which branch the user is viewing, so you always
/// know something is happening even after switching away.
struct ProcessingBanner: View {
    private var isActive: Bool { ProcessingRegistry.shared.anyProcessing }

    var body: some View {
        if isActive {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text("Cortana working…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - Active Jobs Section

/// Shows background jobs that are actively running.
/// Uses GRDB ValueObservation — fires only when canvas_jobs actually changes.
/// Zero polling overhead compared to the previous 5-second Timer approach.
struct ActiveJobsSection: View {
    @State private var jobs: [WorldTreeJob] = []

    var body: some View {
        Group {
            if !jobs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // Section header
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange)
                        Text("JOBS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(jobs.count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    // Job rows
                    ForEach(jobs) { job in
                        JobRow(job: job)
                    }
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .task {
            // Reactive observation — replaces the 5-second Timer.
            // Fires immediately with current state, then only when canvas_jobs changes.
            guard let dbPool = DatabaseManager.shared.dbPool else { return }
            let observation = ValueObservation.trackingConstantRegion { db -> [WorldTreeJob] in
                try WorldTreeJob
                    .filter(Column("status") == "queued" || Column("status") == "running")
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            }
            do {
                for try await activeJobs in observation.values(in: dbPool) {
                    jobs = activeJobs
                }
            } catch {
                // Observation cancelled (view disappeared) — expected
            }
        }
    }
}

// MARK: - Job Row

private struct JobRow: View {
    let job: WorldTreeJob

    var body: some View {
        HStack(spacing: 6) {
            // Spinning indicator for running
            if job.status == .running {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Running")
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.7))
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Queued")
            }

            Text(job.displayCommand)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
