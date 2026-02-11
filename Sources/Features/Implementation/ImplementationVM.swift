import Foundation

/// ViewModel for implementation branches — dispatches to daemon, monitors progress, handles completion.
@MainActor
final class ImplementationVM: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case dispatching
        case running
        case completing
        case done
        case failed(String)
    }

    @Published var phase: Phase = .preparing
    @Published var logLines: [String] = []
    @Published var taskId: String?

    private let branch: Branch
    private var logTailer: LogTailer?
    private var completionWatcher: DispatchSourceFileSystemObject?
    private var logTask: Task<Void, Never>?

    init(branch: Branch) {
        self.branch = branch
    }

    // MARK: - Dispatch

    func dispatch() async {
        guard let context = branch.contextSnapshot else {
            phase = .failed("No context available for dispatch")
            return
        }

        phase = .dispatching

        // Determine project from tree
        let tree = try? TreeStore.shared.getTree(branch.treeId)
        let project = tree?.project ?? "cortana-core"

        // Send to daemon
        guard let id = await DaemonService.shared.dispatch(
            message: context,
            project: project,
            priority: "normal"
        ) else {
            phase = .failed(DaemonService.shared.lastError ?? "Dispatch failed")
            return
        }

        taskId = id

        // Store task ID on branch
        try? TreeStore.shared.updateBranch(branch.id, daemonTaskId: id)

        phase = .running

        // Start tailing logs
        startLogTailing(taskId: id)

        // Watch for completion
        watchForCompletion(taskId: id)
    }

    // MARK: - Resume (for branches that already have a daemon task)

    func resume() {
        guard let id = branch.daemonTaskId else { return }
        taskId = id
        phase = .running
        startLogTailing(taskId: id)
        watchForCompletion(taskId: id)
    }

    // MARK: - Log Tailing

    private func startLogTailing(taskId: String) {
        let logPath = "\(CortanaConstants.daemonLogsDir)/daemon-\(taskId).log"
        let logURL = URL(fileURLWithPath: logPath)
        let tailer = LogTailer(fileURL: logURL)
        self.logTailer = tailer

        logTask = Task {
            for await line in tailer.tail() {
                await MainActor.run {
                    self.logLines.append(line)
                    // Cap at 5000 lines to prevent memory issues
                    if self.logLines.count > 5000 {
                        self.logLines.removeFirst(100)
                    }
                }
            }
        }
    }

    // MARK: - Completion Detection

    private func watchForCompletion(taskId: String) {
        let markerPath = "\(CortanaConstants.completedMarkersDir)/completed-\(taskId)"

        // Poll for completion marker file
        Task {
            while phase == .running {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

                if FileManager.default.fileExists(atPath: markerPath) {
                    await handleCompletion(taskId: taskId)
                    break
                }
            }
        }
    }

    private func handleCompletion(taskId: String) async {
        phase = .completing

        // Generate summary from log output
        let lastLines = logLines.suffix(20).joined(separator: "\n")
        let summary = extractSummary(from: lastLines)

        // Update branch
        try? TreeStore.shared.updateBranch(
            branch.id,
            status: .completed,
            summary: summary
        )

        phase = .done
        stop()
    }

    /// Extract a meaningful summary from log output
    private func extractSummary(from output: String) -> String {
        // Look for session completion message
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // Find the last substantive output (not timestamps/metadata)
        let substantive = lines.filter { line in
            !line.hasPrefix("[") && !line.hasPrefix("---") && line.count > 10
        }

        if let last = substantive.last {
            return String(last.prefix(300))
        }

        return "Implementation completed (\(logLines.count) log lines)"
    }

    // MARK: - Actions

    func openInTerminal() {
        guard let id = taskId else { return }
        let script = """
            tell application "Terminal"
                do script "tmux attach-session -t cortana-\(id)"
                activate
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func stop() {
        logTask?.cancel()
        logTailer?.stop()
        logTailer = nil
    }
}
