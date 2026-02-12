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
    @Published var branchPath: [Branch] = []
    @Published var siblings: [Branch] = []

    @Published var shouldAutoScroll: Bool = true
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
            branchPath = try TreeStore.shared.branchPath(to: branchId)
            siblings = try TreeStore.shared.getSiblings(of: branchId)
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
            canvasLog("[BranchVM] starting response, hasAPI=\(bridge.hasAPIAccess)")

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
                    if accumulated.count < 100 {
                        canvasLog("[BranchVM] text chunk: \(chunk.prefix(50))")
                    }

                case .toolStart(let name, let input):
                    canvasLog("[BranchVM] toolStart: \(name)")
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
                    canvasLog("[BranchVM] done, turns=\(usage.turnCount)")
                    tokenUsage = usage

                case .error(let msg):
                    canvasLog("[BranchVM] error: \(msg)")
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

    /// Edit a message by creating a new branch with the edited content.
    /// Returns the new branch ID for navigation, or nil on failure.
    func editMessage(_ message: Message, newContent: String) -> String? {
        guard let branch = branch, let sessionId = branch.sessionId else { return nil }

        do {
            // Find the fork point (message before the edited one)
            let forkFromId: Int? = {
                if let idx = messages.firstIndex(where: { $0.id == message.id }), idx > 0 {
                    return messages[idx - 1].id
                }
                return nil
            }()

            let editTitle = "Edit: \(String(newContent.prefix(40)))"

            // Create new branch
            let newBranch = try TreeStore.shared.createBranch(
                treeId: branch.treeId,
                parentBranch: branch.id,
                forkFromMessage: forkFromId,
                type: branch.branchType,
                title: editTitle,
                model: branch.model
            )

            guard let newSessionId = newBranch.sessionId else { return nil }

            // Copy messages up to the edited message
            _ = try MessageStore.shared.copyMessages(
                from: sessionId,
                upTo: message.id,
                to: newSessionId
            )

            // Insert the edited content as a new user message
            _ = try MessageStore.shared.sendMessage(
                sessionId: newSessionId,
                role: .user,
                content: newContent
            )

            // Update tree timestamp
            try TreeStore.shared.updateTreeTimestamp(branch.treeId)

            return newBranch.id
        } catch {
            self.error = error.localizedDescription
            return nil
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
