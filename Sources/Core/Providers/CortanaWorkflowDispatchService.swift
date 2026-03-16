import Foundation

@MainActor
final class CortanaWorkflowDispatchService {
    static let shared = CortanaWorkflowDispatchService()

    private var activeDispatchIds: Set<String> = []

    private init() {}

    var activeIds: Set<String> {
        activeDispatchIds
    }

    @discardableResult
    func dispatch(
        message: String,
        project: String,
        workingDirectory: String,
        preferredModelId: String? = nil,
        template: WorkflowTemplate? = nil,
        origin: DispatchOrigin = .workflow,
        systemPromptOverride: String? = nil
    ) -> String {
        let plan = CortanaWorkflowPlanner.plan(
            message: message,
            preferredModelId: preferredModelId,
            template: template
        )
        let prompt = CortanaWorkflowPlanner.composePrimaryPrompt(message: message, template: template)
        let primaryId = UUID().uuidString

        let reviewStage = plan.reviewer.flatMap { review -> WorkflowStage? in
            guard review.runsAutomatically else { return nil }

            return WorkflowStage(
                dispatchId: UUID().uuidString,
                label: reviewerLabel(template: template, review: review),
                prompt: "",
                modelId: review.modelId,
                systemPrompt: CortanaWorkflowPlanner.composeReviewerSystemPrompt(
                    review: review,
                    template: template,
                    extraSystemPrompt: systemPromptOverride
                ),
                origin: .review,
                review: review
            )
        }

        let primaryStage = WorkflowStage(
            dispatchId: primaryId,
            label: primaryLabel(for: prompt, template: template),
            prompt: prompt,
            modelId: plan.primaryModelId,
            systemPrompt: CortanaWorkflowPlanner.composeSystemPrompt(
                template: template,
                extraSystemPrompt: systemPromptOverride
            ),
            origin: origin,
            review: nil
        )

        seedDispatchRecord(
            id: primaryStage.dispatchId,
            label: primaryStage.label,
            modelId: primaryStage.modelId,
            project: project,
            workingDirectory: workingDirectory,
            origin: primaryStage.origin.rawValue
        )

        Task { [weak self] in
            await self?.runStage(
                primaryStage,
                project: project,
                workingDirectory: workingDirectory,
                originalTask: prompt,
                template: template,
                reviewStage: reviewStage
            )
        }

        return primaryId
    }

    private func runStage(
        _ stage: WorkflowStage,
        project: String,
        workingDirectory: String,
        originalTask: String,
        template: WorkflowTemplate?,
        reviewStage: WorkflowStage?
    ) async {
        activeDispatchIds.insert(stage.dispatchId)

        if stage.review != nil {
            seedDispatchRecord(
                id: stage.dispatchId,
                label: stage.label,
                modelId: stage.modelId,
                project: project,
                workingDirectory: workingDirectory,
                origin: stage.origin.rawValue
            )
        }

        updateDispatchStatus(stage.dispatchId, status: .running, startedAt: Date())
        JobOutputStreamStore.shared.beginStream(
            id: stage.dispatchId,
            kind: .dispatch,
            command: stage.label,
            project: project
        )

        guard let provider = ProviderManager.shared.makeEphemeralProvider(forModelId: stage.modelId) else {
            failDispatch(stage.dispatchId, error: "No provider available for \(ModelCatalog.label(for: stage.modelId))")
            JobOutputStreamStore.shared.endStream(
                id: stage.dispatchId,
                status: WorldTreeDispatch.DispatchStatus.failed.rawValue,
                error: "No provider available"
            )
            activeDispatchIds.remove(stage.dispatchId)
            return
        }

        let health = await provider.checkHealth()
        guard health.isUsable else {
            failDispatch(stage.dispatchId, error: health.statusLabel)
            JobOutputStreamStore.shared.endStream(
                id: stage.dispatchId,
                status: WorldTreeDispatch.DispatchStatus.failed.rawValue,
                error: health.statusLabel
            )
            activeDispatchIds.remove(stage.dispatchId)
            return
        }

        let context = ProviderSendContext(
            message: stage.prompt,
            sessionId: UUID().uuidString,
            branchId: stage.dispatchId,
            model: stage.modelId,
            workingDirectory: workingDirectory,
            project: project,
            isNewSession: true,
            systemPromptOverride: stage.systemPrompt,
            extendedThinking: stage.modelId.contains("opus")
        )

        let stream = provider.send(context: context)
        var transcript = ""
        var finalError: String?
        var usage = SessionTokenUsage()

        for await event in stream {
            switch event {
            case .text(let text):
                transcript.append(text)
                JobOutputStreamStore.shared.appendOutput(id: stage.dispatchId, chunk: text)

            case .thinking(let text):
                let rendered = "\n[thinking]\n\(text)\n"
                transcript.append(rendered)
                JobOutputStreamStore.shared.appendOutput(id: stage.dispatchId, chunk: rendered)

            case .toolStart(let name, let input):
                let rendered = "\n[tool:start] \(name)\n\(input)\n"
                transcript.append(rendered)
                JobOutputStreamStore.shared.appendOutput(id: stage.dispatchId, chunk: rendered)

            case .toolEnd(let name, let result, let isError):
                let rendered = "\n[tool:\(isError ? "error" : "done")] \(name)\n\(result)\n"
                transcript.append(rendered)
                JobOutputStreamStore.shared.appendOutput(id: stage.dispatchId, chunk: rendered)

            case .done(let finalUsage):
                usage = finalUsage

            case .error(let error):
                finalError = error
            }
        }

        if let finalError {
            failDispatch(stage.dispatchId, error: finalError, resultText: transcript)
            JobOutputStreamStore.shared.endStream(
                id: stage.dispatchId,
                status: WorldTreeDispatch.DispatchStatus.failed.rawValue,
                error: finalError
            )
            activeDispatchIds.remove(stage.dispatchId)
            return
        }

        let reviewSource = transcript

        if let reviewStage {
            let handoff = "\n\n[workflow] \(reviewStage.label) queued with \(ModelCatalog.label(for: reviewStage.modelId)).\n"
            transcript.append(handoff)
            JobOutputStreamStore.shared.appendOutput(id: stage.dispatchId, chunk: handoff)
        }

        completeDispatch(stage.dispatchId, resultText: transcript, usage: usage)
        JobOutputStreamStore.shared.endStream(
            id: stage.dispatchId,
            status: WorldTreeDispatch.DispatchStatus.completed.rawValue
        )
        activeDispatchIds.remove(stage.dispatchId)

        if let reviewStage {
            let reviewerPrompt = CortanaWorkflowPlanner.composeReviewerPrompt(
                review: reviewStage.review!,
                originalTask: originalTask,
                primaryModelId: stage.modelId,
                primaryResult: reviewSource
            )
            let queuedReviewStage = WorkflowStage(
                dispatchId: reviewStage.dispatchId,
                label: reviewStage.label,
                prompt: reviewerPrompt,
                modelId: reviewStage.modelId,
                systemPrompt: reviewStage.systemPrompt,
                origin: reviewStage.origin,
                review: reviewStage.review
            )
            await runStage(
                queuedReviewStage,
                project: project,
                workingDirectory: workingDirectory,
                originalTask: originalTask,
                template: template,
                reviewStage: nil
            )
        }
    }

    private func seedDispatchRecord(
        id: String,
        label: String,
        modelId: String,
        project: String,
        workingDirectory: String,
        origin: String
    ) {
        let record = WorldTreeDispatch(
            id: id,
            project: project,
            message: label,
            model: modelId,
            status: .queued,
            workingDirectory: workingDirectory,
            origin: origin
        )

        do {
            try DatabaseManager.shared.write { db in
                try record.insert(db)
            }
        } catch {
            wtLog("[WorkflowDispatch] Failed to seed dispatch \(id.prefix(8)): \(error)")
        }
    }

    private func updateDispatchStatus(
        _ id: String,
        status: WorldTreeDispatch.DispatchStatus,
        startedAt: Date? = nil
    ) {
        do {
            try DatabaseManager.shared.write { db in
                if let startedAt {
                    try db.execute(
                        sql: "UPDATE canvas_dispatches SET status = ?, started_at = ? WHERE id = ?",
                        arguments: [status.rawValue, startedAt, id]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE canvas_dispatches SET status = ? WHERE id = ?",
                        arguments: [status.rawValue, id]
                    )
                }
            }
        } catch {
            wtLog("[WorkflowDispatch] Failed to update dispatch \(id.prefix(8)): \(error)")
        }
    }

    private func completeDispatch(_ id: String, resultText: String, usage: SessionTokenUsage) {
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        UPDATE canvas_dispatches
                        SET status = 'completed', result_text = ?, result_tokens_in = ?,
                            result_tokens_out = ?, completed_at = datetime('now')
                        WHERE id = ?
                        """,
                    arguments: [
                        resultText,
                        usage.totalInputTokens + usage.cacheHitTokens,
                        usage.totalOutputTokens,
                        id
                    ]
                )
            }
        } catch {
            wtLog("[WorkflowDispatch] Failed to complete dispatch \(id.prefix(8)): \(error)")
        }
    }

    private func failDispatch(_ id: String, error errorMessage: String, resultText: String? = nil) {
        do {
            try DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        UPDATE canvas_dispatches
                        SET status = 'failed', error = ?, result_text = COALESCE(?, result_text),
                            completed_at = datetime('now')
                        WHERE id = ?
                        """,
                    arguments: [errorMessage, resultText, id]
                )
            }
        } catch {
            wtLog("[WorkflowDispatch] Failed to mark dispatch \(id.prefix(8)) failed: \(error)")
        }
    }

    private func primaryLabel(for prompt: String, template: WorkflowTemplate?) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template {
            return "\(template.name): \(trimmed)"
        }
        return trimmed
    }

    private func reviewerLabel(template: WorkflowTemplate?, review: CortanaWorkflowReviewPlan) -> String {
        if let template {
            return "\(template.name) \(review.mode.label)"
        }
        return review.mode.label
    }

    private struct WorkflowStage {
        let dispatchId: String
        let label: String
        let prompt: String
        let modelId: String
        let systemPrompt: String?
        let origin: DispatchOrigin
        let review: CortanaWorkflowReviewPlan?
    }
}
