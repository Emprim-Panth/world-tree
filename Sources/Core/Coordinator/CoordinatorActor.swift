import Foundation
import GRDB
import os.log

private let coordLog = Logger(subsystem: "com.forgeandcode.WorldTree", category: "Coordinator")

// MARK: - Coordinator Actor

/// Orchestrates multi-task plans using a local Ollama model as the coordinator brain.
///
/// Flow:
///   1. User provides a goal + project + working directory
///   2. Ollama decomposes the goal into a task list (JSON)
///   3. Tasks are inserted into coordinator_tasks, linked to a coordinator_plans row
///   4. Each task is dispatched to Claude Code via CortanaWorkflowDispatchService
///   5. Dispatch completions are observed via ValueObservation on canvas_dispatches
///   6. After each task, Ollama reviews the result and we advance to the next task
///   7. When all tasks are done, the plan is marked complete
@MainActor
final class CoordinatorActor: ObservableObject {
    static let shared = CoordinatorActor()

    @Published private(set) var activePlans: [CoordinatorPlan] = []
    @Published private(set) var planTasks: [String: [CoordinatorTask]] = [:]  // planId → tasks
    @Published private(set) var isDecomposing = false
    @Published private(set) var decompositionStatus: String = ""

    private var dispatchObservation: DatabaseCancellable?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        loadActivePlans()
        startDispatchObservation()
    }

    func stop() {
        dispatchObservation?.cancel()
        dispatchObservation = nil
    }

    // MARK: - Start Plan

    /// Decomposes `goal` into tasks using Ollama, then begins execution.
    func startPlan(
        goal: String,
        project: String,
        workingDirectory: String,
        ollamaModel: String = "llama3.2"
    ) async {
        isDecomposing = true
        decompositionStatus = "Asking Ollama to decompose goal..."

        do {
            // 1. Check Ollama health
            let isUp = await OllamaClient.shared.isRunning()
            guard isUp else {
                isDecomposing = false
                decompositionStatus = "Ollama not running"
                return
            }

            // 2. Decompose goal into tasks
            let tasks = try await decomposeGoal(goal, model: ollamaModel, project: project)
            guard !tasks.isEmpty else {
                isDecomposing = false
                decompositionStatus = "No tasks generated"
                return
            }

            decompositionStatus = "Creating \(tasks.count) tasks..."

            // 3. Create plan record
            let plan = CoordinatorPlan(
                project: project,
                workingDirectory: workingDirectory,
                goal: goal,
                ollamaModel: ollamaModel,
                taskCount: tasks.count
            )
            try CoordinatorStore.insertPlan(plan)

            // 4. Create task records
            let taskRecords = tasks.enumerated().map { idx, t in
                CoordinatorTask(
                    planId: plan.id,
                    sequence: idx,
                    title: t.title,
                    description: t.description
                )
            }
            try CoordinatorStore.insertTasks(taskRecords)

            isDecomposing = false
            decompositionStatus = ""

            // 5. Load and start execution
            loadActivePlans()
            try await advancePlan(plan.id)

        } catch {
            isDecomposing = false
            decompositionStatus = "Error: \(error.localizedDescription)"
            coordLog.error("[Coordinator] Plan start failed: \(error)")
        }
    }

    // MARK: - Cancel Plan

    func cancelPlan(_ planId: String) {
        do {
            try CoordinatorStore.updatePlanStatus(planId, status: .cancelled)
        } catch {
            coordLog.error("[Coordinator] Cancel failed: \(error)")
        }
        loadActivePlans()
    }

    // MARK: - Advance Plan

    /// Dispatches the next ready task in the plan. Called after a task completes.
    private func advancePlan(_ planId: String) async throws {
        let tasks = try CoordinatorStore.fetchTasks(forPlan: planId)
        let completedIds = Set(tasks.filter { $0.status == .completed }.map { $0.id })
        let failedCount = tasks.filter { $0.status == .failed }.count

        // If too many failures, pause the plan
        if failedCount >= 2 {
            try CoordinatorStore.updatePlanStatus(planId, status: .failed, error: "\(failedCount) tasks failed")
            loadActivePlans()
            return
        }

        // All done?
        let doneCount = tasks.filter { $0.isTerminal }.count
        if doneCount == tasks.count {
            try CoordinatorStore.updatePlanStatus(planId, status: .completed)
            try CoordinatorStore.updatePlanProgress(planId, taskCount: tasks.count, completedTaskCount: completedIds.count)
            loadActivePlans()
            coordLog.info("[Coordinator] Plan \(planId.prefix(8)) completed")
            return
        }

        // Find the next queued task whose dependencies are satisfied
        guard let nextTask = tasks.first(where: { task in
            guard task.status == .queued else { return false }
            guard let deps = try? JSONDecoder().decode([String].self, from: Data(task.dependsOn.utf8)) else { return true }
            return deps.allSatisfy { completedIds.contains($0) }
        }) else {
            // No ready tasks — something is running or blocked
            return
        }

        // Get the plan's working directory
        guard let plan = activePlans.first(where: { $0.id == planId }) else { return }

        // Mark task as dispatched
        try CoordinatorStore.updateTaskStatus(nextTask.id, status: .dispatched)
        try CoordinatorStore.updatePlanStatus(planId, status: .running)

        // Dispatch to Claude Code
        let prompt = buildTaskPrompt(task: nextTask, plan: plan, allTasks: tasks, completedIds: completedIds)
        let dispatchId = CortanaWorkflowDispatchService.shared.dispatch(
            message: prompt,
            project: plan.project,
            workingDirectory: plan.workingDirectory,
            origin: .workflow,
            systemPromptOverride: "You are executing task \(nextTask.sequence + 1) of \(tasks.count) in a multi-step plan. Be concise and focused."
        )

        try CoordinatorStore.updateTaskStatus(nextTask.id, status: .dispatched, dispatchId: dispatchId)

        let completedCount = tasks.filter { $0.status == .completed }.count
        try CoordinatorStore.updatePlanProgress(planId, taskCount: tasks.count, completedTaskCount: completedCount)

        loadActivePlans()
        coordLog.info("[Coordinator] Dispatched task \(nextTask.sequence + 1)/\(tasks.count) for plan \(planId.prefix(8))")
    }

    // MARK: - Dispatch Observation

    /// Watches canvas_dispatches for completions that belong to coordinator tasks.
    private func startDispatchObservation() {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }

        let observation = ValueObservation.tracking { db -> [WorldTreeDispatch] in
            guard try db.tableExists("canvas_dispatches"),
                  try db.tableExists("coordinator_tasks") else { return [] }

            // Find dispatches linked to coordinator tasks that just completed/failed
            return try WorldTreeDispatch
                .filter(["completed", "failed"].contains(Column("status")))
                .filter(sql: """
                    id IN (SELECT dispatch_id FROM coordinator_tasks
                           WHERE status IN ('dispatched','running') AND dispatch_id IS NOT NULL)
                    """)
                .fetchAll(db)
        }

        dispatchObservation = observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { error in
                coordLog.error("[Coordinator] Observation error: \(error)")
            },
            onChange: { [weak self] completedDispatches in
                Task { @MainActor [weak self] in
                    await self?.handleCompletedDispatches(completedDispatches)
                }
            }
        )
    }

    private func handleCompletedDispatches(_ dispatches: [WorldTreeDispatch]) async {
        for dispatch in dispatches {
            do {
                guard let task = try CoordinatorStore.fetchTask(byDispatchId: dispatch.id) else { continue }
                // Skip if already handled
                guard task.status == .dispatched || task.status == .running else { continue }

                let newStatus: CoordinatorTask.TaskStatus = dispatch.status == .completed ? .completed : .failed
                var summary: String? = nil

                // Ask Ollama to summarize the result (brief, non-blocking)
                if dispatch.status == .completed, let resultText = dispatch.resultText, !resultText.isEmpty {
                    summary = await summarizeResult(resultText, taskTitle: task.title)
                }

                try CoordinatorStore.updateTaskStatus(
                    task.id,
                    status: newStatus,
                    resultSummary: summary,
                    error: dispatch.error
                )

                coordLog.info("[Coordinator] Task \(task.sequence + 1) \(newStatus.rawValue) for plan \(task.planId.prefix(8))")

                // Advance to the next task
                try await advancePlan(task.planId)

            } catch {
                coordLog.error("[Coordinator] Handle completion failed: \(error)")
            }
        }
    }

    // MARK: - Ollama Decomposition

    private struct DecomposedTask {
        let title: String
        let description: String
    }

    private func decomposeGoal(_ goal: String, model: String, project: String) async throws -> [DecomposedTask] {
        let prompt = """
        You are a software engineering coordinator. Break down the following goal into 2-6 concrete, \
        actionable tasks for a code agent to execute sequentially.

        Project: \(project)
        Goal: \(goal)

        Respond with ONLY a valid JSON array. Each element must have "title" (short) and "description" \
        (full instruction for the agent, 1-3 sentences). No other text outside the JSON.

        Example:
        [
          {"title": "Update the model", "description": "Add the new `score` field to the User model and run the migration."},
          {"title": "Wire the API endpoint", "description": "Create a POST /score endpoint that validates input and persists the score."}
        ]
        """

        let messages = [OllamaChatMessage(role: "user", content: prompt)]
        let response = try await OllamaClient.shared.chat(model: model, messages: messages)

        return parseTaskJSON(response)
    }

    private func parseTaskJSON(_ response: String) -> [DecomposedTask] {
        // Extract JSON array from response (model may wrap it in markdown)
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonCandidate: String

        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") {
            jsonCandidate = String(text[start...end])
        } else {
            jsonCandidate = text
        }

        guard let data = jsonCandidate.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            coordLog.warning("[Coordinator] Failed to parse task JSON: \(response.prefix(200))")
            return []
        }

        return raw.compactMap { dict in
            guard let title = dict["title"], let desc = dict["description"] else { return nil }
            return DecomposedTask(title: title, description: desc)
        }
    }

    private func summarizeResult(_ text: String, taskTitle: String) async -> String? {
        guard text.count > 100 else { return text }
        let truncated = String(text.prefix(3000))
        let prompt = """
        Summarize in one sentence what was accomplished for the task "\(taskTitle)":

        \(truncated)
        """
        let messages = [OllamaChatMessage(role: "user", content: prompt)]

        // Best-effort — ignore errors
        guard let activePlan = activePlans.first else { return nil }
        return try? await OllamaClient.shared.chat(model: activePlan.ollamaModel, messages: messages)
    }

    // MARK: - Prompt Builder

    private func buildTaskPrompt(
        task: CoordinatorTask,
        plan: CoordinatorPlan,
        allTasks: [CoordinatorTask],
        completedIds: Set<String>
    ) -> String {
        var parts: [String] = []
        parts.append("## Coordinator Plan: \(plan.goal)")
        parts.append("Task \(task.sequence + 1) of \(allTasks.count): **\(task.title)**")
        parts.append(task.description)

        // Summarize completed tasks for context
        let completed = allTasks.filter { completedIds.contains($0.id) }
        if !completed.isEmpty {
            parts.append("\n### Already completed:")
            for ct in completed {
                let summary = ct.resultSummary.map { " — \($0)" } ?? ""
                parts.append("- \(ct.title)\(summary)")
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Data Loading

    private func loadActivePlans() {
        do {
            activePlans = try CoordinatorStore.fetchActivePlans()
            // Also pull recent completed plans
            let all = try CoordinatorStore.fetchAllPlans(limit: 10)
            let combined = activePlans + all.filter { !$0.isActive }
            // Dictionary(uniqueKeysWithValues:) crashes on duplicate IDs — use safe loop instead.
            var deduped: [String: CoordinatorPlan] = [:]
            for plan in combined { deduped[plan.id] = plan }
            activePlans = Array(deduped.values).sorted { $0.createdAt > $1.createdAt }

            // Load tasks for each active plan
            for plan in activePlans where plan.isActive {
                if let tasks = try? CoordinatorStore.fetchTasks(forPlan: plan.id) {
                    planTasks[plan.id] = tasks
                }
            }
        } catch {
            coordLog.error("[Coordinator] Load failed: \(error)")
        }
    }
}
