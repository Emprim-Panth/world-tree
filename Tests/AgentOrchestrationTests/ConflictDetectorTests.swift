import XCTest
import GRDB
@testable import WorldTree

// MARK: - Conflict Detector Tests

@MainActor
final class ConflictDetectorTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "conflict-test-\(UUID().uuidString).sqlite"
        dbPool = try DatabasePool(path: dbPath)
        try MigrationManager.migrate(dbPool)
    }

    override func tearDown() async throws {
        dbPool = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    // MARK: - Two Sessions Same File = Conflict

    func testTwoSessionsSameFileConflict() throws {
        // Insert two active sessions
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO agent_sessions (id, project, working_directory, status, started_at, last_activity_at)
                VALUES ('s1', 'Proj', '/tmp', 'tool_use', datetime('now'), datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO agent_sessions (id, project, working_directory, status, started_at, last_activity_at)
                VALUES ('s2', 'Proj', '/tmp', 'writing', datetime('now'), datetime('now'))
                """)

            // Both touch the same file
            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s1', '/tmp/shared.swift', 'edit', 'geordi', 'Proj', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s2', '/tmp/shared.swift', 'edit', 'worf', 'Proj', datetime('now'))
                """)
        }

        // Query for conflicts
        let conflicts = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT ft1.file_path, ft1.session_id AS s1, ft2.session_id AS s2
                FROM agent_file_touches ft1
                JOIN agent_file_touches ft2 ON ft1.file_path = ft2.file_path
                JOIN agent_sessions a1 ON ft1.session_id = a1.id
                JOIN agent_sessions a2 ON ft2.session_id = a2.id
                WHERE ft1.session_id < ft2.session_id
                  AND ft1.action = 'edit' AND ft2.action = 'edit'
                  AND a1.status NOT IN ('completed', 'failed', 'interrupted')
                  AND a2.status NOT IN ('completed', 'failed', 'interrupted')
                """)
        }

        XCTAssertEqual(conflicts.count, 1)
    }

    // MARK: - Reads Don't Conflict

    func testReadsDoNotConflict() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO agent_sessions (id, project, working_directory, status, started_at, last_activity_at)
                VALUES ('s1', 'Proj', '/tmp', 'tool_use', datetime('now'), datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO agent_sessions (id, project, working_directory, status, started_at, last_activity_at)
                VALUES ('s2', 'Proj', '/tmp', 'tool_use', datetime('now'), datetime('now'))
                """)

            // Both read the same file
            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s1', '/tmp/shared.swift', 'read', 'geordi', 'Proj', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s2', '/tmp/shared.swift', 'read', 'worf', 'Proj', datetime('now'))
                """)
        }

        let conflicts = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT ft1.file_path
                FROM agent_file_touches ft1
                JOIN agent_file_touches ft2 ON ft1.file_path = ft2.file_path
                WHERE ft1.session_id < ft2.session_id
                  AND ft1.action = 'edit' AND ft2.action = 'edit'
                """)
        }

        XCTAssertEqual(conflicts.count, 0)
    }

    // MARK: - Completed Session No Conflict

    func testCompletedSessionNoConflict() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO agent_sessions (id, project, working_directory, status, started_at, last_activity_at)
                VALUES ('s1', 'Proj', '/tmp', 'completed', datetime('now'), datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO agent_sessions (id, project, working_directory, status, started_at, last_activity_at)
                VALUES ('s2', 'Proj', '/tmp', 'tool_use', datetime('now'), datetime('now'))
                """)

            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s1', '/tmp/file.swift', 'edit', 'geordi', 'Proj', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s2', '/tmp/file.swift', 'edit', 'worf', 'Proj', datetime('now'))
                """)
        }

        let conflicts = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT ft1.file_path
                FROM agent_file_touches ft1
                JOIN agent_file_touches ft2 ON ft1.file_path = ft2.file_path
                JOIN agent_sessions a1 ON ft1.session_id = a1.id
                JOIN agent_sessions a2 ON ft2.session_id = a2.id
                WHERE ft1.session_id < ft2.session_id
                  AND ft1.action = 'edit' AND ft2.action = 'edit'
                  AND a1.status NOT IN ('completed', 'failed', 'interrupted')
                  AND a2.status NOT IN ('completed', 'failed', 'interrupted')
                """)
        }

        XCTAssertEqual(conflicts.count, 0)
    }

    // MARK: - No Self-Conflict

    func testNoSelfConflict() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO agent_sessions (id, project, working_directory, status, started_at, last_activity_at)
                VALUES ('s1', 'Proj', '/tmp', 'tool_use', datetime('now'), datetime('now'))
                """)

            // Same session edits the same file twice
            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s1', '/tmp/file.swift', 'edit', 'geordi', 'Proj', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO agent_file_touches (session_id, file_path, action, agent_name, project, touched_at)
                VALUES ('s1', '/tmp/file.swift', 'edit', 'geordi', 'Proj', datetime('now', '+1 second'))
                """)
        }

        let conflicts = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT ft1.file_path
                FROM agent_file_touches ft1
                JOIN agent_file_touches ft2 ON ft1.file_path = ft2.file_path
                WHERE ft1.session_id < ft2.session_id
                  AND ft1.action = 'edit' AND ft2.action = 'edit'
                """)
        }

        XCTAssertEqual(conflicts.count, 0)
    }
}
