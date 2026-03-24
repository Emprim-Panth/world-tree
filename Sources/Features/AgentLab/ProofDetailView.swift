import SwiftUI

struct ProofDetailView: View {
    let session: AgentLabViewModel.AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var proof: ProofData? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var selectedScreenshotIndex: Int? = nil
    @State private var showCastPlayer = false

    struct ProofData: Decodable {
        let summary: String?
        let agentSummary: String?
        let buildStatus: String?
        let buildOutput: String?
        let screenshotPaths: [String]?
        let screenshots: [String]?
        let recordingPath: String?
        let taskDescription: String?

        // Normalise — proof files may use either key
        var resolvedSummary: String? { agentSummary ?? summary }
        var resolvedScreenshots: [String] { screenshotPaths ?? screenshots ?? [] }
        var resolvedBuildOutput: String? { buildOutput }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project)
                        .font(.headline)
                    Text(session.displayTask.prefix(80) + (session.displayTask.count > 80 ? "…" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                buildStatusBadge
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if isLoading {
                ProgressView("Loading proof…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                proofContent
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear { fetchProof() }
    }

    // MARK: - Proof Content

    @ViewBuilder
    private var proofContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Agent summary
                if let summary = proof?.resolvedSummary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Agent Summary")
                        Text(summary)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                }

                // Task description
                if let taskDesc = proof?.taskDescription, !taskDesc.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Task")
                        Text(taskDesc)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // Screenshots carousel
                let screenshots = proof?.resolvedScreenshots ?? []
                if !screenshots.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Screenshots (\(screenshots.count))")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(screenshots.indices, id: \.self) { i in
                                    screenshotThumb(path: screenshots[i], index: i)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }

                // Build output
                if let buildOutput = proof?.resolvedBuildOutput, !buildOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            sectionHeader("Build Output")
                            Spacer()
                            Text("last 20 lines")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        ScrollView {
                            Text(last20Lines(buildOutput))
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 200)
                        .background(Color.black.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Recording
                if let recordingPath = proof?.recordingPath, !recordingPath.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Recording")
                        HStack(spacing: 8) {
                            Image(systemName: "film.stack")
                                .foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: recordingPath).lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Play") {
                                showCastPlayer = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .sheet(isPresented: $showCastPlayer) {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Recording Playback")
                                    .font(.headline)
                                Spacer()
                                Button("Close") { showCastPlayer = false }
                            }
                            .padding()
                            CastPlayer(castPath: recordingPath)
                        }
                        .frame(minWidth: 600, minHeight: 400)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private func screenshotThumb(path: String, index: Int) -> some View {
        Group {
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 180, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(selectedScreenshotIndex == index ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .onTapGesture { selectedScreenshotIndex = index }
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 180, height: 120)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                            Text("Not found")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    )
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var buildStatusBadge: some View {
        let status = session.buildStatus ?? proof?.buildStatus ?? "unknown"
        let (bg, fg): (Color, Color) = {
            switch status {
            case "succeeded": return (.green.opacity(0.15), .green)
            case "failed": return (.red.opacity(0.15), .red)
            default: return (.gray.opacity(0.15), .secondary)
            }
        }()
        return Text(status.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
    }

    private func last20Lines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.suffix(20).joined(separator: "\n")
    }

    private func fetchProof() {
        guard let sessionId = Optional(session.id),
              let url = URL(string: "http://127.0.0.1:4863/agent/\(sessionId)/proof") else {
            isLoading = false
            errorMessage = "Invalid session ID"
            return
        }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 404 {
                    await MainActor.run {
                        isLoading = false
                        errorMessage = "No proof file found for this session."
                    }
                    return
                }
                let decoder = JSONDecoder()
                if let decoded = try? decoder.decode(ProofData.self, from: data) {
                    await MainActor.run {
                        proof = decoded
                        isLoading = false
                    }
                } else {
                    await MainActor.run {
                        isLoading = false
                        errorMessage = "Could not parse proof file."
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Failed to load proof: \(error.localizedDescription)"
                }
            }
        }
    }
}
