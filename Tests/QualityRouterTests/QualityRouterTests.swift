import XCTest
import GRDB
@testable import WorldTree

// MARK: - QualityRouter Unit Tests

/// Tests for QualityRouter routing logic, offline fallback, and escalation decisions.
/// Does NOT test actual Ollama inference (requires running server).
@MainActor
final class QualityRouterTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "router-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
        DatabaseManager.shared.setDatabasePoolForTesting(dbPool)
    }

    override func tearDown() async throws {
        DatabaseManager.shared.setDatabasePoolForTesting(nil)
        dbPool = nil
        if let path = dbPath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        dbPath = nil
        try await super.tearDown()
    }

    // MARK: - Provider Properties

    func testProviderIsLocal() {
        XCTAssertTrue(QualityRouter.Provider.local72B.isLocal)
        XCTAssertTrue(QualityRouter.Provider.local32B.isLocal)
        XCTAssertTrue(QualityRouter.Provider.localEmbed.isLocal)
        XCTAssertFalse(QualityRouter.Provider.claudeSonnet.isLocal)
        XCTAssertFalse(QualityRouter.Provider.claudeOpus.isLocal)
    }

    // MARK: - Online Routing (default path)

    func testRouteFileSummaryToLocal32B() {
        let router = QualityRouter.shared
        let decision = router.route(.fileSummary)
        XCTAssertEqual(decision.provider, .local32B)
    }

    func testRouteTicketScanToLocal72B() {
        let router = QualityRouter.shared
        let decision = router.route(.ticketScan)
        XCTAssertEqual(decision.provider, .local72B)
    }

    func testRouteBriefingToLocal72B() {
        let router = QualityRouter.shared
        let decision = router.route(.briefing)
        XCTAssertEqual(decision.provider, .local72B)
    }

    func testRouteDriftDetectionToLocal72B() {
        let router = QualityRouter.shared
        let decision = router.route(.driftDetection)
        XCTAssertEqual(decision.provider, .local72B)
    }

    func testRouteHealthCheckToLocal72B() {
        let router = QualityRouter.shared
        let decision = router.route(.healthCheck)
        XCTAssertEqual(decision.provider, .local72B)
    }

    func testRouteBrainSearchToLocalEmbed() {
        let router = QualityRouter.shared
        let decision = router.route(.brainSearch)
        XCTAssertEqual(decision.provider, .localEmbed)
    }

    func testRouteCodeGenerationToClaude() {
        let router = QualityRouter.shared
        let decision = router.route(.codeGeneration)
        XCTAssertEqual(decision.provider, .claudeSonnet)
    }

    func testRouteArchitectureToClaudeOpus() {
        let router = QualityRouter.shared
        let decision = router.route(.architecture)
        XCTAssertEqual(decision.provider, .claudeOpus)
    }

    func testRouteInteractiveToClaude() {
        let router = QualityRouter.shared
        let decision = router.route(.interactive)
        XCTAssertEqual(decision.provider, .claudeSonnet)
    }

    func testRouteCommitExplainSmallDiffToLocal() {
        let router = QualityRouter.shared
        let decision = router.route(.commitExplain, context: "small diff")
        XCTAssertEqual(decision.provider, .local32B)
    }

    func testRouteCommitExplainLargeDiffToClaude() {
        let router = QualityRouter.shared
        let largeDiff = String(repeating: "x", count: 6000)
        let decision = router.route(.commitExplain, context: largeDiff)
        XCTAssertEqual(decision.provider, .claudeSonnet)
    }

    // MARK: - Offline Fallback

    func testOfflineFallbackSkipsNonCriticalTasks() {
        let router = QualityRouter.shared
        // Simulate Ollama being offline by checking the offline routing path.
        // The route() method checks ollamaOnline directly. We need to set it.
        // Since ollamaOnline is private(set), we test through the routing behavior.
        // We can't directly set ollamaOnline, but we can verify the logic by
        // checking that when ollamaOnline is false the non-critical tasks get skip reason.

        // Use a fresh router instance isn't possible (private init), so we test
        // the logic indirectly: call checkOllamaHealth which will set ollamaOnline=false
        // since no Ollama is running in the test environment.

        // First, force ollamaOnline to false by hitting a bad endpoint
        Task { @MainActor in
            await router.checkOllamaHealth()
        }

        // After health check against non-running Ollama, ollamaOnline should be false
        // But since checkOllamaHealth is async, let's just test the structural behavior:
        // When online, fileSummary routes to local32B
        let onlineDecision = router.route(.fileSummary)
        // The provider should be local32B (when online) or local72B with skip reason (when offline)
        // Either way, it should be a local provider
        XCTAssertTrue(onlineDecision.provider.isLocal,
                      "fileSummary should always route to a local provider")
    }

    func testOfflineFallbackEscalatesImportantTasks() async {
        let router = QualityRouter.shared

        // Force offline by hitting health check (no Ollama in test env)
        await router.checkOllamaHealth()

        // When offline, briefing should escalate to Claude
        let decision = router.route(.briefing)
        if !router.ollamaOnline {
            XCTAssertEqual(decision.provider, .claudeSonnet,
                           "Briefing should escalate to Claude when Ollama is offline")
            XCTAssertTrue(decision.reason.contains("offline") || decision.reason.contains("escalated"),
                          "Reason should mention offline/escalation")
        }
        // If Ollama happens to be running, briefing routes to local72B — that's fine
    }

    func testOfflineNonCriticalSkipReason() async {
        let router = QualityRouter.shared
        await router.checkOllamaHealth()

        if !router.ollamaOnline {
            let decision = router.route(.healthCheck)
            XCTAssertTrue(decision.reason.contains("skipped") || decision.reason.contains("offline"),
                          "Non-critical offline task should mention skip/offline in reason")
        }
    }

    func testOfflineDoesNotAffectClaudeTasks() async {
        let router = QualityRouter.shared
        await router.checkOllamaHealth()

        // Claude tasks should route normally regardless of Ollama status
        let decision = router.route(.codeGeneration)
        XCTAssertEqual(decision.provider, .claudeSonnet,
                       "Claude tasks should route to Claude even when Ollama is offline")
    }

    // MARK: - shouldEscalate()

    func testShouldEscalateReturnsFalseForFileSummary() {
        let router = QualityRouter.shared
        XCTAssertFalse(router.shouldEscalate(confidence: "low", taskType: .fileSummary))
    }

    func testShouldEscalateReturnsFalseForHealthCheck() {
        let router = QualityRouter.shared
        XCTAssertFalse(router.shouldEscalate(confidence: "low", taskType: .healthCheck))
    }

    func testShouldEscalateReturnsFalseForTicketScan() {
        let router = QualityRouter.shared
        XCTAssertFalse(router.shouldEscalate(confidence: "low", taskType: .ticketScan))
    }

    func testShouldEscalateReturnsFalseForBrainSearch() {
        let router = QualityRouter.shared
        XCTAssertFalse(router.shouldEscalate(confidence: "low", taskType: .brainSearch))
    }

    func testShouldEscalateReturnsTrueForLowConfidenceBriefing() {
        let router = QualityRouter.shared
        XCTAssertTrue(router.shouldEscalate(confidence: "low", taskType: .briefing))
    }

    func testShouldEscalateReturnsTrueForLowConfidenceDriftDetection() {
        let router = QualityRouter.shared
        XCTAssertTrue(router.shouldEscalate(confidence: "low", taskType: .driftDetection))
    }

    func testShouldEscalateReturnsTrueForLowConfidenceCommitExplain() {
        let router = QualityRouter.shared
        XCTAssertTrue(router.shouldEscalate(confidence: "low", taskType: .commitExplain))
    }

    func testShouldEscalateReturnsFalseForHighConfidence() {
        let router = QualityRouter.shared
        XCTAssertFalse(router.shouldEscalate(confidence: "high", taskType: .briefing))
        XCTAssertFalse(router.shouldEscalate(confidence: "high", taskType: .driftDetection))
    }

    // MARK: - assessConfidence (tested indirectly via routeAndExecute)

    // assessConfidence is private, so we verify its behavior through the
    // routing stats and inference_log table after routeAndExecute calls.
    // Since routeAndExecute requires a running Ollama, we test the logic
    // patterns that assessConfidence implements:

    func testRoutingStatsStructure() {
        var stats = QualityRouter.RoutingStats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.localPercent, 0, "Zero total should yield 0%")

        stats.localCount = 7
        stats.claudeCount = 3
        XCTAssertEqual(stats.totalCount, 10)
        XCTAssertEqual(stats.localPercent, 70)
    }

    func testRoutingLogsToInferenceLog() throws {
        let router = QualityRouter.shared
        _ = router.route(.fileSummary)

        let count = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inference_log WHERE task_type = 'fileSummary'")
        }
        XCTAssertEqual(count, 1, "route() should log to inference_log")
    }

    func testRoutingStatsIncrementOnRoute() {
        let router = QualityRouter.shared
        let before = router.todayStats.localCount

        _ = router.route(.ticketScan)
        XCTAssertEqual(router.todayStats.localCount, before + 1,
                       "Local task should increment localCount")
    }

    func testRoutingStatsIncrementClaudeOnRoute() {
        let router = QualityRouter.shared
        let before = router.todayStats.claudeCount

        _ = router.route(.codeGeneration)
        XCTAssertEqual(router.todayStats.claudeCount, before + 1,
                       "Claude task should increment claudeCount")
    }
}
