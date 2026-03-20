import Foundation

@MainActor
final class StreamRecoveryCoordinator {
    static let shared = StreamRecoveryCoordinator()
    static let autoResumeMaxAttempts = 2

    private struct ActiveAttempt {
        let branchId: String
        let subscriptionId: UUID
        var madeProgress = false
    }

    private let claudeBridge = ClaudeBridge()
    private let retryDelaySeconds: TimeInterval = 3
    private let maxAttempts = autoResumeMaxAttempts

    private var observer: NSObjectProtocol?
    private var scheduledChecks: [String: Task<Void, Never>] = [:]
    private var activeAttempts: [String: ActiveAttempt] = [:]

    private init() {}

    func activate() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: .streamRecoveryStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let sessionId = note.userInfo?["sessionId"] as? String else { return }
                self?.scheduleRecoveryCheck(sessionId: sessionId)
            }
        }

        for sessionId in StreamRecoveryStore.shared.allPendingSessionIds() {
            // Purge stale entries that carry the legacy "session-" prefix —
            // these can never resolve to a real branch and would log a warning on every launch.
            if sessionId.hasPrefix("session-") {
                wtLog("[StreamRecoveryCoordinator] Purging stale legacy key: \(sessionId.prefix(20))…")
                StreamRecoveryStore.shared.clearPending(sessionId: sessionId)
                continue
            }
            scheduleRecoveryCheck(sessionId: sessionId, delay: .seconds(2))
        }
    }

    func scheduleRecoveryCheck(sessionId: String, delay: Duration = .milliseconds(250)) {
        // Don't schedule if auto-resume is already exhausted — prevents repeated
        // "attempts exhausted" log spam from applyMessages / autoResumeIfNeeded callbacks.
        if let pending = StreamRecoveryStore.shared.pendingRecovery(for: sessionId),
           pending.attemptCount >= maxAttempts {
            return
        }
        scheduledChecks[sessionId]?.cancel()
        scheduledChecks[sessionId] = Task { @MainActor [weak self] in
            defer { self?.scheduledChecks.removeValue(forKey: sessionId) }
            try? await Task.sleep(for: delay)
            await self?.attemptRecoveryIfNeeded(sessionId: sessionId)
        }
    }

    private func attemptRecoveryIfNeeded(sessionId: String) async {
        guard activeAttempts[sessionId] == nil else { return }
        guard let pending = StreamRecoveryStore.shared.pendingRecovery(for: sessionId) else { return }
        guard ProviderManager.shared.activeProvider != nil else {
            wtLog("[StreamRecoveryCoordinator] Provider not ready — deferring recovery for session \(sessionId.prefix(8))")
            scheduleRecoveryCheck(sessionId: sessionId, delay: .seconds(3))
            return
        }

        if pending.attemptCount >= maxAttempts {
            wtLog("[StreamRecoveryCoordinator] Auto-resume attempts exhausted for session \(sessionId.prefix(8))")
            return
        }

        if let lastAttemptAt = pending.lastAttemptAt,
           Date().timeIntervalSince(lastAttemptAt) < retryDelaySeconds {
            return
        }

        guard let branch = try? TreeStore.shared.getBranchBySessionId(sessionId) else {
            wtLog("[StreamRecoveryCoordinator] No branch found for pending session \(sessionId.prefix(8))")
            return
        }

        guard !ActiveStreamRegistry.shared.isActive(branch.id) else { return }

        let draftKey = "draft.\(branch.id)"
        if let draft = UserDefaults.standard.string(forKey: draftKey),
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            wtLog("[StreamRecoveryCoordinator] Deferring recovery for session \(sessionId.prefix(8)) — draft is not empty")
            return
        }

        let tree = try? TreeStore.shared.getTree(branch.treeId)
        let workingDirectory = tree?.workingDirectory ?? NSHomeDirectory()
        let project = tree?.project
        let model = branch.model
            ?? UserDefaults.standard.string(forKey: AppConstants.defaultModelKey)
            ?? AppConstants.defaultModel
        let checkpointContext: String? = {
            guard let (summary, createdAt) = SessionRotator.latestCheckpoint(sessionId: sessionId),
                  Date().timeIntervalSince(createdAt) < 259_200 else {
                return nil
            }
            return summary
        }()

        do {
            try MessageStore.shared.ensureSession(sessionId: sessionId, workingDirectory: workingDirectory)
        } catch {
            wtLog("[StreamRecoveryCoordinator] Failed to ensure session \(sessionId.prefix(8)): \(error)")
        }

        let partialContent = pending.partialContent
        let prompt: String
        if partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = "[Continue your previous response from exactly where it left off. Do not restart or summarize.]"
        } else {
            prompt = """
            [Your previous response was interrupted. The user already saw the following partial text:
            \(partialContent)

            Continue immediately after that exact text. Output only the continuation. Do not repeat, restart, summarize, or quote the text above.]
            """
        }
        let context = SendContextBuilder.build(
            message: prompt,
            sessionId: sessionId,
            branchId: branch.id,
            model: model,
            workingDirectory: workingDirectory,
            project: project,
            checkpointContext: checkpointContext,
            isSessionStale: true
        )

        wtLog("[StreamRecoveryCoordinator] Auto-resuming session \(sessionId.prefix(8)) on branch \(branch.id.prefix(8))")
        _ = StreamRecoveryStore.shared.markAttemptStarted(sessionId: sessionId)
        Task { await StreamCacheManager.shared.openStreamFile(sessionId: sessionId) }

        let subscriptionId = ActiveStreamRegistry.shared.startStream(
            branchId: branch.id,
            sessionId: sessionId,
            treeId: branch.treeId,
            projectName: project,
            initialContent: partialContent,
            stream: claudeBridge.send(context: context),
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handle(event: event, sessionId: sessionId)
                }
            }
        )

        guard let subscriptionId else {
            wtLog("[StreamRecoveryCoordinator] Failed to subscribe to recovery stream for session \(sessionId.prefix(8))")
            return
        }

        activeAttempts[sessionId] = ActiveAttempt(branchId: branch.id, subscriptionId: subscriptionId)
    }

    private func handle(event: BridgeEvent, sessionId: String) async {
        guard var attempt = activeAttempts[sessionId] else { return }

        switch event {
        case .text(let token):
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !attempt.madeProgress {
                attempt.madeProgress = true
                activeAttempts[sessionId] = attempt
            }

        case .thinking, .toolStart, .toolEnd:
            break

        case .done:
            if attempt.madeProgress {
                StreamRecoveryStore.shared.clearPending(sessionId: sessionId)
            }
            finishAttempt(sessionId: sessionId, branchId: attempt.branchId, subscriptionId: attempt.subscriptionId)
            if !attempt.madeProgress, StreamRecoveryStore.shared.hasPendingRecovery(sessionId: sessionId) {
                scheduleRecoveryCheck(sessionId: sessionId, delay: .seconds(retryDelaySeconds))
            }

        case .error:
            finishAttempt(sessionId: sessionId, branchId: attempt.branchId, subscriptionId: attempt.subscriptionId)
            // Only retry if this attempt made real progress (produced tokens). Silent failures
            // (resume started a new session but produced no content) won't be fixed by retrying
            // immediately — they'd just write a second identical error message to the DB.
            if attempt.madeProgress, StreamRecoveryStore.shared.hasPendingRecovery(sessionId: sessionId) {
                scheduleRecoveryCheck(sessionId: sessionId, delay: .seconds(retryDelaySeconds))
            }
        }
    }

    private func finishAttempt(sessionId: String, branchId: String, subscriptionId: UUID) {
        ActiveStreamRegistry.shared.unsubscribe(branchId: branchId, id: subscriptionId)
        activeAttempts.removeValue(forKey: sessionId)
    }
}
