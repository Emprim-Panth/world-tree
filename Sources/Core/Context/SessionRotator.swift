import Foundation
import GRDB

// MARK: - Session Rotator

/// Orchestrates CLI session rotation when context pressure exceeds thresholds.
///
/// When the estimated context usage passes 75%, the rotator:
/// 1. Generates a checkpoint summary via BranchSummarizer
/// 2. Clears the CLI session mapping (forces fresh session on next send)
/// 3. Returns the checkpoint to prepend to the next message
/// 4. Persists the checkpoint to DB for history
/// 5. Logs observability events
@MainActor
enum SessionRotator {

    /// Guard against concurrent rotation attempts — two rapid sends at high
    /// pressure could both pass shouldRotate, wasting API calls.
    private static var isRotating = false

    // MARK: - Public API

    /// Check if rotation is needed and perform it if so.
    /// Returns the checkpoint summary if rotation occurred, nil otherwise.
    static func rotateIfNeeded(
        sessionId: String,
        branchId: String,
        messages: [Message],
        toolEventCount: Int,
        provider: any LLMProvider
    ) async -> String? {
        guard !isRotating else { return nil }
        isRotating = true
        defer { isRotating = false }

        let (tokens, level) = ContextPressureEstimator.estimate(
            messages: messages,
            toolEventCount: toolEventCount
        )

        guard level.shouldRotate else { return nil }

        guard UserDefaults.standard.object(forKey: AppConstants.autoCompactEnabledKey) as? Bool ?? true else {
            wtLog("[SessionRotator] Auto-compact disabled — skipping rotation")
            return nil
        }

        // Check per-branch compaction mode
        let mode = branchCompactionMode(branchId: branchId)
        switch mode {
        case .frozen:
            wtLog("[SessionRotator] Branch \(branchId.prefix(8))… compaction frozen — skipping rotation")
            return nil
        case .manual:
            wtLog("[SessionRotator] Branch \(branchId.prefix(8))… compaction manual — skipping auto-rotation (pressure: \(level.rawValue))")
            return nil
        case .auto:
            break
        }

        wtLog("[SessionRotator] Pressure \(level.rawValue) (\(tokens) est. tokens) — rotating session \(sessionId)")
        return await performRotation(
            sessionId: sessionId,
            branchId: branchId,
            estimatedTokens: tokens,
            messageCount: messages.count,
            provider: provider
        )
    }

    /// Force a rotation regardless of current pressure.
    static func forceRotate(
        sessionId: String,
        branchId: String,
        provider: any LLMProvider
    ) async -> String? {
        let messages = (try? MessageStore.shared.getMessages(sessionId: sessionId)) ?? []
        let eventCount = EventStore.shared.activityCount(branchId: branchId, minutes: 999_999)

        wtLog("[SessionRotator] Forced rotation for session \(sessionId)")
        return await performRotation(
            sessionId: sessionId,
            branchId: branchId,
            estimatedTokens: ContextPressureEstimator.estimate(messages: messages, toolEventCount: eventCount).tokens,
            messageCount: messages.count,
            provider: provider
        )
    }

    // MARK: - Core Rotation

    private static func performRotation(
        sessionId: String,
        branchId: String,
        estimatedTokens: Int,
        messageCount: Int,
        provider: any LLMProvider
    ) async -> String? {
        // 1. Generate checkpoint summary (with fallback for pathologically short results)
        let minCheckpointLength = 200
        var checkpoint = await BranchSummarizer.shared.checkpoint(sessionId: sessionId)

        if let cp = checkpoint, cp.count < minCheckpointLength {
            wtLog("[SessionRotator] Checkpoint too short (\(cp.count) chars) — falling back to raw message dump")
            checkpoint = BranchSummarizer.shared.rawCheckpoint(sessionId: sessionId)
        }

        guard let checkpoint else {
            wtLog("[SessionRotator] Failed to generate checkpoint — skipping rotation")
            return nil
        }

        // 2. Clear CLI session mapping (next send() starts fresh)
        provider.rotateSession(for: sessionId)

        // 3. Persist checkpoint to DB
        persistCheckpoint(
            sessionId: sessionId,
            branchId: branchId,
            summary: checkpoint,
            estimatedTokens: estimatedTokens,
            messageCount: messageCount
        )

        // 4. Log events
        EventStore.shared.log(
            branchId: branchId,
            sessionId: sessionId,
            type: .contextCheckpoint,
            data: [
                "estimated_tokens": estimatedTokens,
                "message_count": messageCount,
                "summary_length": checkpoint.count,
            ]
        )

        EventStore.shared.log(
            branchId: branchId,
            sessionId: sessionId,
            type: .sessionRotation,
            data: ["reason": "pressure_threshold"]
        )

        wtLog("[SessionRotator] Rotation complete — checkpoint \(checkpoint.count) chars, cleared CLI mapping")
        return checkpoint
    }

    // MARK: - Persistence

    private static func persistCheckpoint(
        sessionId: String,
        branchId: String,
        summary: String,
        estimatedTokens: Int,
        messageCount: Int
    ) {
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO canvas_context_checkpoints
                        (session_id, branch_id, summary, estimated_tokens_at_rotation, message_count_at_rotation, created_at)
                        VALUES (?, ?, ?, ?, ?, datetime('now'))
                        """,
                    arguments: [sessionId, branchId, summary, estimatedTokens, messageCount]
                )
            }
        } catch {
            wtLog("[SessionRotator] Failed to persist checkpoint: \(error)")
        }
    }

    // MARK: - Snapshot (no-rotate)

    /// Write a plain-text continuity snapshot without rotating the session.
    /// Called on document close/disappear — no API call, just persists recent turns.
    /// The next open will restore this as context if it's the most recent checkpoint.
    static func writeSnapshot(sessionId: String, branchId: String, summary: String, messageCount: Int) {
        // Capture value types — safe to hand off to a background Task even after
        // the calling ViewModel is deallocated.
        let sid = sessionId, bid = branchId, sum = summary, count = messageCount
        Task { @MainActor in
            do {
                try await DatabaseManager.shared.asyncWrite { db in
                    try db.execute(
                        sql: """
                            INSERT INTO canvas_context_checkpoints
                            (session_id, branch_id, summary, estimated_tokens_at_rotation, message_count_at_rotation, created_at)
                            VALUES (?, ?, ?, 0, ?, datetime('now'))
                            """,
                        arguments: [sid, bid, sum, count]
                    )
                }
                wtLog("[SessionRotator] Snapshot checkpoint written for \(sid.prefix(8))… (\(sum.count) chars, \(count) turns)")
            } catch {
                wtLog("[SessionRotator] Failed to write snapshot: \(error)")
            }
        }
    }

    // MARK: - Compaction Mode

    /// Read compaction mode for a branch from DB.
    static func branchCompactionMode(branchId: String) -> CompactionMode {
        (try? DatabaseManager.shared.read { db in
            let raw: String? = try Row.fetchOne(
                db,
                sql: "SELECT compaction_mode FROM canvas_branches WHERE id = ?",
                arguments: [branchId]
            )?["compaction_mode"]
            return CompactionMode(rawValue: raw ?? "auto") ?? .auto
        }) ?? .auto
    }

    /// Update compaction mode for a branch.
    static func setCompactionMode(_ mode: CompactionMode, branchId: String) {
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: "UPDATE canvas_branches SET compaction_mode = ? WHERE id = ?",
                    arguments: [mode.rawValue, branchId]
                )
            }
            wtLog("[SessionRotator] Set compaction mode to '\(mode.rawValue)' for branch \(branchId.prefix(8))…")
        } catch {
            wtLog("[SessionRotator] Failed to update compaction mode: \(error)")
        }
    }

    // MARK: - Query

    /// Get the most recent checkpoint for a session (for display/debugging).
    static func latestCheckpoint(sessionId: String) -> (summary: String, createdAt: Date)? {
        do {
            return try DatabaseManager.shared.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT summary, created_at
                        FROM canvas_context_checkpoints
                        WHERE session_id = ?
                        ORDER BY created_at DESC
                        LIMIT 1
                        """,
                    arguments: [sessionId]
                )
                guard let row else { return nil }
                let summary: String = row["summary"]
                let createdAt: Date = row["created_at"] ?? Date()
                return (summary: summary, createdAt: createdAt)
            }
        } catch {
            return nil
        }
    }

    /// Count of rotations for a session.
    static func rotationCount(sessionId: String) -> Int {
        (try? DatabaseManager.shared.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM canvas_context_checkpoints WHERE session_id = ?",
                arguments: [sessionId]
            ) ?? 0
        }) ?? 0
    }
}
