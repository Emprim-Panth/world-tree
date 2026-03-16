import XCTest
import GRDB
@testable import WorldTree

// MARK: - Event Rule Store Tests

@MainActor
final class EventRuleStoreTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "eventrule-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
    }

    override func tearDown() async throws {
        dbPool = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    // MARK: - Rule Persistence

    func testRuleInsertAndFetch() throws {
        let rule = EventRule(
            name: "Test Rule",
            triggerType: .errorCount,
            triggerConfig: "{\"threshold\":\"3\"}",
            actionType: .notify,
            actionConfig: "{\"message\":\"Too many errors\"}"
        )

        try dbPool.write { db in try rule.insert(db) }

        let fetched = try dbPool.read { db in
            try EventRule.fetchAll(db, sql: "SELECT * FROM event_trigger_rules")
        }

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Test Rule")
        XCTAssertEqual(fetched.first?.triggerType, .errorCount)
        XCTAssertEqual(fetched.first?.actionType, .notify)
        XCTAssertTrue(fetched.first?.enabled ?? false)
    }

    // MARK: - Cooldown

    func testCooldownPreventsRetrigger() {
        let rule = EventRule(
            name: "Cooldown Test",
            triggerType: .errorCount,
            triggerConfig: "{}",
            actionType: .notify,
            actionConfig: "{}",
            lastTriggeredAt: Date() // just triggered
        )

        XCTAssertTrue(rule.isOnCooldown)
    }

    func testNoCooldownWhenNeverTriggered() {
        let rule = EventRule(
            name: "Fresh Rule",
            triggerType: .errorCount,
            triggerConfig: "{}",
            actionType: .notify,
            actionConfig: "{}",
            lastTriggeredAt: nil
        )

        XCTAssertFalse(rule.isOnCooldown)
    }

    func testCooldownExpiresAfter30Min() {
        let rule = EventRule(
            name: "Expired Cooldown",
            triggerType: .errorCount,
            triggerConfig: "{}",
            actionType: .notify,
            actionConfig: "{}",
            lastTriggeredAt: Date().addingTimeInterval(-1900) // 31+ min ago
        )

        XCTAssertFalse(rule.isOnCooldown)
    }

    // MARK: - Disabled Rule Skipped

    func testDisabledRuleSkipped() throws {
        let rule = EventRule(
            name: "Disabled",
            enabled: false,
            triggerType: .errorCount,
            triggerConfig: "{\"threshold\":\"1\"}",
            actionType: .notify,
            actionConfig: "{}"
        )

        try dbPool.write { db in try rule.insert(db) }

        let fetched = try dbPool.read { db in
            try EventRule.fetchAll(db, sql: "SELECT * FROM event_trigger_rules WHERE enabled = 1")
        }

        XCTAssertEqual(fetched.count, 0)
    }

    // MARK: - Config Accessors

    func testTriggerConfigDict() {
        let rule = EventRule(
            name: "Config Test",
            triggerType: .errorCount,
            triggerConfig: "{\"threshold\":\"5\",\"project\":\"WorldTree\"}",
            actionType: .notify,
            actionConfig: "{}"
        )

        XCTAssertEqual(rule.triggerConfigDict["threshold"], "5")
        XCTAssertEqual(rule.triggerConfigDict["project"], "WorldTree")
    }

    func testActionConfigDict() {
        let rule = EventRule(
            name: "Action Test",
            triggerType: .errorCount,
            triggerConfig: "{}",
            actionType: .dispatchAgent,
            actionConfig: "{\"agent\":\"geordi\",\"prompt_template\":\"Fix it\"}"
        )

        XCTAssertEqual(rule.actionConfigDict["agent"], "geordi")
        XCTAssertEqual(rule.actionConfigDict["prompt_template"], "Fix it")
    }

    // MARK: - Display Descriptions

    func testTriggerDescription() {
        let rule = EventRule(
            name: "Desc Test",
            triggerType: .errorCount,
            triggerConfig: "{\"threshold\":\"3\"}",
            actionType: .notify,
            actionConfig: "{}"
        )
        XCTAssertTrue(rule.triggerDescription.contains("3"))
    }

    func testActionDescription() {
        let rule = EventRule(
            name: "Desc Test",
            triggerType: .errorCount,
            triggerConfig: "{}",
            actionType: .dispatchAgent,
            actionConfig: "{\"agent\":\"worf\"}"
        )
        XCTAssertTrue(rule.actionDescription.contains("worf"))
    }
}
