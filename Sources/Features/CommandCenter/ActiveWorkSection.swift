import SwiftUI

/// Live feed of all active work across all projects.
/// Combines dispatches, jobs, and Claude tmux sessions.
struct ActiveWorkSection: View {
    let dispatches: [WorldTreeDispatch]
    let jobs: [WorldTreeJob]
    let onCancel: (String) -> Void

    var body: some View {
        if dispatches.isEmpty && jobs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader

                VStack(spacing: 4) {
                    ForEach(dispatches) { dispatch in
                        dispatchRow(dispatch)
                    }

                    ForEach(jobs) { job in
                        jobRow(job)
                    }
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
            Text("ACTIVE WORK")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(dispatches.count + jobs.count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.green)
                .accessibilityLabel("\(dispatches.count + jobs.count) active tasks")
        }
        .accessibilityElement(children: .combine)
    }

    private func dispatchRow(_ dispatch: WorldTreeDispatch) -> some View {
        HStack(spacing: 8) {
            // Status indicator
            if dispatch.status == .running {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Running")
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Queued")
            }

            // Project badge
            Text(dispatch.project)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.8))
                .clipShape(Capsule())

            // Message
            Text(dispatch.displayMessage)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Model badge
            if let model = dispatch.model {
                Text(modelShortName(model))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Duration
            if let dur = dispatch.durationString {
                Text(dur)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Cancel
            Button {
                onCancel(dispatch.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Cancel dispatch")
            .accessibilityLabel("Cancel dispatch")
            .accessibilityHint("Stops this running dispatch")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func jobRow(_ job: WorldTreeJob) -> some View {
        HStack(spacing: 8) {
            if job.status == .running {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Job running")
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Job queued")
            }

            Text("job")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.8))
                .clipShape(Capsule())

            Text(job.displayCommand)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func modelShortName(_ model: String) -> String {
        if model.contains("opus") { return "opus" }
        if model.contains("sonnet") { return "sonnet" }
        if model.contains("haiku") { return "haiku" }
        return model.components(separatedBy: "-").last ?? model
    }
}
