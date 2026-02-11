import Foundation
import GRDB

@MainActor
final class BranchViewModel: ObservableObject {
    @Published var branch: Branch?
    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var isResponding: Bool = false
    @Published var streamingResponse: String = ""
    @Published var toolActivities: [ToolActivity] = []
    @Published var tokenUsage: SessionTokenUsage?
    @Published var error: String?

    private let branchId: String
    private var observation: AnyDatabaseCancellable?
    private var claudeBridge: ClaudeBridge?
    private var responseTask: Task<Void, Never>?

    init(branchId: String) {
        self.branchId = branchId
    }

    func load() {
        isLoading = true
        do {
            branch = try TreeStore.shared.getBranch(branchId)
            if let sessionId = branch?.sessionId {
                messages = try MessageStore.shared.getMessages(sessionId: sessionId)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Start observing messages for live updates (GRDB ValueObservation)
    func startObserving() {
        guard let dbPool = DatabaseManager.shared.dbPool,
              let sessionId = branch?.sessionId else { return }

        let observation = ValueObservation.tracking { db -> [Message] in
            let sql = """
                SELECT m.*,
                    (SELECT COUNT(*) FROM canvas_branches cb
                     WHERE cb.fork_from_message_id = m.id) as has_branches
                FROM messages m
                WHERE m.session_id = ?
                ORDER BY m.timestamp ASC
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sessionId])
        }

        self.observation = observation.start(in: dbPool, onError: { error in
            Task { @MainActor in
                self.error = error.localizedDescription
            }
        }, onChange: { [weak self] messages in
            Task { @MainActor in
                self?.messages = messages
            }
        })
    }

    func sendMessage() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let sessionId = branch?.sessionId else { return }
        guard !isResponding else { return }

        inputText = ""

        do {
            _ = try MessageStore.shared.sendMessage(
                sessionId: sessionId,
                role: .user,
                content: content
            )
            if let treeId = branch?.treeId {
                try TreeStore.shared.updateTreeTimestamp(treeId)
            }
        } catch {
            self.error = error.localizedDescription
            inputText = content
            return
        }

        requestResponse(for: content, sessionId: sessionId)
    }

    /// Send message via direct API with tool execution, or CLI fallback.
    private func requestResponse(for message: String, sessionId: String) {
        isResponding = true
        streamingResponse = ""
        toolActivities = []

        // Persist bridge across messages for API state continuity
        if claudeBridge == nil {
            claudeBridge = ClaudeBridge()
        }
        let bridge = claudeBridge!

        let tree = try? TreeStore.shared.getTree(branch?.treeId ?? "")
        let branchCwd: String? = {
            guard let sid = branch?.sessionId else { return nil }
            return try? MessageStore.shared.getSessionWorkingDirectory(sessionId: sid)
        }()

        responseTask = Task {
            var accumulated = ""

            let stream = bridge.send(
                message: message,
                sessionId: sessionId,
                branchId: branchId,
                model: branch?.model,
                workingDirectory: branchCwd ?? tree?.workingDirectory,
                project: tree?.project
            )

            for await event in stream {
                switch event {
                case .text(let chunk):
                    accumulated += chunk
                    streamingResponse = accumulated

                case .toolStart(let name, let input):
                    let activity = ToolActivity(
                        name: name,
                        input: input,
                        status: .running
                    )
                    toolActivities.append(activity)

                case .toolEnd(let name, let result, let isError):
                    if let idx = toolActivities.lastIndex(where: { $0.name == name && $0.status == .running }) {
                        toolActivities[idx].status = isError ? .failed : .completed
                        toolActivities[idx].output = String(result.prefix(200))
                    }

                case .done(let usage):
                    tokenUsage = usage

                case .error(let msg):
                    self.error = msg
                }
            }

            // Save final text response as assistant message
            let finalResponse = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalResponse.isEmpty {
                do {
                    _ = try MessageStore.shared.sendMessage(
                        sessionId: sessionId,
                        role: .assistant,
                        content: finalResponse
                    )
                } catch {
                    self.error = error.localizedDescription
                }
            }

            streamingResponse = ""
            isResponding = false
            toolActivities = []
        }
    }

    func cancelResponse() {
        claudeBridge?.cancel()
        responseTask?.cancel()
        isResponding = false
        streamingResponse = ""
        toolActivities = []
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        cancelResponse()
        // Persist bridge state before stopping
        claudeBridge = nil
    }
}
