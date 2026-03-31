import SwiftUI

/// Live diff display fed by FSEvents file watching + git diff.
struct LiveDiffView: View {
    let projectPath: String
    @State private var diffOutput: String = ""
    @State private var changedFiles: [String] = []
    @State private var isRefreshing = false
    private let debounceInterval: TimeInterval = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Live Changes")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Button { Task { await refreshDiff() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 8))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }

            if changedFiles.isEmpty {
                Text("No uncommitted changes")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                // File list
                ForEach(changedFiles, id: \.self) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill").font(.system(size: 8))
                            .foregroundStyle(Palette.warning)
                        Text(file)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                    }
                }

                // Diff content
                if !diffOutput.isEmpty {
                    ScrollView {
                        Text(diffOutput)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Palette.codeBackground))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground))
        .onAppear { Task { await refreshDiff() } }
        .task { await startWatching() }
    }

    private func startWatching() async {
        // Poll every 3 seconds for file changes (FSEvents would be better but polling is simpler and reliable)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            await refreshDiff()
        }
    }

    private func refreshDiff() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Get changed files
        let statResult = await runGit(["status", "--porcelain", "--short"], in: projectPath)
        let files = statResult.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0.dropFirst(3)) } // Drop status prefix (e.g., " M ")

        // Get diff
        let diff = await runGit(["diff", "--stat", "--no-color"], in: projectPath)

        await MainActor.run {
            changedFiles = files
            diffOutput = diff
        }
    }

    private func runGit(_ args: [String], in directory: String) async -> String {
        await withCheckedContinuation { continuation in
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: directory)
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
