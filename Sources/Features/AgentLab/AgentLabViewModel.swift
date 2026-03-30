import Foundation

@MainActor @Observable final class AgentLabViewModel {
    var activeSession: AgentSession? = nil
    var sessions: [AgentSession] = []
    var liveScreenshotData: Data? = nil
    var isLoadingLive = false

    private var pollTask: Task<Void, Never>?

    struct AgentSession: Identifiable, Decodable {
        let id: String
        let project: String
        let task: String?
        let startedAt: String?
        let completedAt: String?
        let buildStatus: String?
        let proofPath: String?

        var buildStatusColor: String {
            switch buildStatus {
            case "succeeded": return "green"
            case "failed": return "red"
            default: return "secondary"
            }
        }

        var buildStatusEmoji: String {
            switch buildStatus {
            case "succeeded": return "✅"
            case "failed": return "❌"
            default: return "⚠️"
            }
        }

        var displayTask: String {
            task ?? "Unnamed task"
        }

        var elapsedText: String {
            guard let startedAt else { return "" }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: startedAt)
            if date == nil {
                // Try without fractional seconds
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime]
                date = f2.date(from: startedAt)
            }
            if date == nil {
                // Try simple format
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                date = df.date(from: startedAt)
            }
            guard let date else { return "" }
            let interval = Date().timeIntervalSince(date)
            if interval < 60 { return "\(Int(interval))s" }
            if interval < 3600 { return "\(Int(interval / 60))m" }
            return "\(Int(interval / 3600))h \(Int((interval.truncatingRemainder(dividingBy: 3600)) / 60))m"
        }

        var relativeTimestamp: String {
            let dateStr = completedAt ?? startedAt ?? ""
            guard !dateStr.isEmpty else { return "" }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: dateStr)
            if date == nil {
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime]
                date = f2.date(from: dateStr)
            }
            if date == nil {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                date = df.date(from: dateStr)
            }
            guard let date else { return dateStr }
            let interval = Date().timeIntervalSince(date)
            if interval < 60 { return "just now" }
            if interval < 3600 { return "\(Int(interval / 60))m ago" }
            if interval < 86400 { return "\(Int(interval / 3600))h ago" }
            return "\(Int(interval / 86400))d ago"
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() { pollTask?.cancel() }

    func refresh() async {
        await refreshActive()
        await refreshSessions()
        if activeSession != nil { await refreshLiveScreenshot() }
    }

    private func refreshActive() async {
        guard let url = URL(string: "http://127.0.0.1:4863/agent/active") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            activeSession = try? JSONDecoder().decode(AgentSession.self, from: data)
        } catch {
            activeSession = nil
        }
    }

    private func refreshSessions() async {
        guard let url = URL(string: "http://127.0.0.1:4863/agent/sessions") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let decoded = try? JSONDecoder().decode([AgentSession].self, from: data) {
                sessions = decoded
            }
        } catch {
            wtLog("[AgentLab] Failed to fetch sessions: \(error)")
        }
    }

    func refreshLiveScreenshot() async {
        guard let session = activeSession,
              let url = URL(string: "http://127.0.0.1:4863/agent/\(session.id)/screenshot") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                liveScreenshotData = data
            }
        } catch {
            // Screenshot fetch is expected to fail when no active session — don't log
        }
    }
}
