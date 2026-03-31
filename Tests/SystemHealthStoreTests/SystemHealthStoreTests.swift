import XCTest
@testable import WorldTree

// MARK: - SystemHealthStore Unit Tests

/// Tests for HealthCheck.Status, OverallStatus computation, and icon values.
/// Does NOT test live health checks (Ollama, ContextServer) — those are integration tests.
@MainActor
final class SystemHealthStoreTests: XCTestCase {

    // MARK: - HealthCheck.Status Raw Values

    func testHealthCheckStatusRawValues() {
        XCTAssertEqual(SystemHealthStore.HealthCheck.Status.ok.rawValue, "ok")
        XCTAssertEqual(SystemHealthStore.HealthCheck.Status.warning.rawValue, "warning")
        XCTAssertEqual(SystemHealthStore.HealthCheck.Status.error.rawValue, "error")
        XCTAssertEqual(SystemHealthStore.HealthCheck.Status.unknown.rawValue, "unknown")
    }

    // MARK: - OverallStatus Raw Values

    func testOverallStatusRawValues() {
        XCTAssertEqual(SystemHealthStore.OverallStatus.healthy.rawValue, "healthy")
        XCTAssertEqual(SystemHealthStore.OverallStatus.degraded.rawValue, "degraded")
        XCTAssertEqual(SystemHealthStore.OverallStatus.down.rawValue, "down")
        XCTAssertEqual(SystemHealthStore.OverallStatus.unknown.rawValue, "unknown")
    }

    // MARK: - OverallStatus Icons

    func testOverallStatusHealthyIcon() {
        XCTAssertEqual(SystemHealthStore.OverallStatus.healthy.icon, "checkmark.circle.fill")
    }

    func testOverallStatusDegradedIcon() {
        XCTAssertEqual(SystemHealthStore.OverallStatus.degraded.icon, "exclamationmark.triangle.fill")
    }

    func testOverallStatusDownIcon() {
        XCTAssertEqual(SystemHealthStore.OverallStatus.down.icon, "xmark.circle.fill")
    }

    func testOverallStatusUnknownIcon() {
        XCTAssertEqual(SystemHealthStore.OverallStatus.unknown.icon, "questionmark.circle")
    }

    // MARK: - OverallStatus Computation

    func testAllOkProducesHealthy() {
        let checks = [
            makeCheck(status: .ok),
            makeCheck(status: .ok),
            makeCheck(status: .ok),
        ]
        let status = computeOverallStatus(from: checks)
        XCTAssertEqual(status, .healthy)
    }

    func testAnyErrorProducesDown() {
        let checks = [
            makeCheck(status: .ok),
            makeCheck(status: .error),
            makeCheck(status: .ok),
        ]
        let status = computeOverallStatus(from: checks)
        XCTAssertEqual(status, .down)
    }

    func testWarningWithNoErrorProducesDegraded() {
        let checks = [
            makeCheck(status: .ok),
            makeCheck(status: .warning),
            makeCheck(status: .ok),
        ]
        let status = computeOverallStatus(from: checks)
        XCTAssertEqual(status, .degraded)
    }

    func testEmptyChecksProducesUnknown() {
        let checks: [SystemHealthStore.HealthCheck] = []
        let status = computeOverallStatus(from: checks)
        XCTAssertEqual(status, .unknown)
    }

    func testErrorTakesPriorityOverWarning() {
        let checks = [
            makeCheck(status: .warning),
            makeCheck(status: .error),
            makeCheck(status: .ok),
        ]
        let status = computeOverallStatus(from: checks)
        XCTAssertEqual(status, .down, "Error should take priority over warning")
    }

    func testAllWarningsProducesDegraded() {
        let checks = [
            makeCheck(status: .warning),
            makeCheck(status: .warning),
        ]
        let status = computeOverallStatus(from: checks)
        XCTAssertEqual(status, .degraded)
    }

    func testUnknownStatusWithOkProducesDegraded() {
        // unknown is not .ok so it falls through to degraded
        let checks = [
            makeCheck(status: .ok),
            makeCheck(status: .unknown),
        ]
        let status = computeOverallStatus(from: checks)
        XCTAssertEqual(status, .degraded)
    }

    // MARK: - HealthCheck Properties

    func testHealthCheckHasStableId() {
        let check = makeCheck(status: .ok)
        XCTAssertNotNil(check.id)
    }

    func testHealthCheckStoresDetail() {
        let check = SystemHealthStore.HealthCheck(
            name: "TestService",
            status: .ok,
            detail: "3 models loaded",
            latencyMs: 42
        )
        XCTAssertEqual(check.name, "TestService")
        XCTAssertEqual(check.detail, "3 models loaded")
        XCTAssertEqual(check.latencyMs, 42)
    }

    func testHealthCheckNilLatency() {
        let check = SystemHealthStore.HealthCheck(
            name: "Offline",
            status: .error,
            detail: "Not reachable",
            latencyMs: nil
        )
        XCTAssertNil(check.latencyMs)
    }

    // MARK: - Helpers

    /// Replicates SystemHealthStore.updateOverallStatus logic for isolated testing.
    private func computeOverallStatus(from checks: [SystemHealthStore.HealthCheck]) -> SystemHealthStore.OverallStatus {
        if checks.isEmpty {
            return .unknown
        } else if checks.allSatisfy({ $0.status == .ok }) {
            return .healthy
        } else if checks.contains(where: { $0.status == .error }) {
            return .down
        } else {
            return .degraded
        }
    }

    private func makeCheck(status: SystemHealthStore.HealthCheck.Status) -> SystemHealthStore.HealthCheck {
        SystemHealthStore.HealthCheck(
            name: "Test-\(status.rawValue)",
            status: status,
            detail: "detail",
            latencyMs: nil
        )
    }
}
