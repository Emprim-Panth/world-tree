import Foundation

// MARK: - SavedServer

struct SavedServer: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var host: String
    var port: Int
    /// How this server was added.
    var source: ServerSource
    var lastConnectedAt: Date?

    // MARK: - Source

    enum ServerSource: String, Codable, Equatable {
        /// Added manually by the user (includes Tailscale hostnames).
        case manual
        /// Discovered automatically via Bonjour/mDNS.
        case bonjour
    }

    // MARK: - Convenience

    static func manual(name: String, host: String, port: Int = 8765) -> SavedServer {
        SavedServer(
            id: UUID().uuidString,
            name: name,
            host: host,
            port: port,
            source: .manual,
            lastConnectedAt: nil
        )
    }

    /// True when the host looks like a Tailscale hostname (`.ts.net` suffix).
    var isTailscale: Bool { host.hasSuffix(".ts.net") }

    // MARK: - Legacy decoding

    /// `isBonjourDiscovered` was the previous field name. Map it to `source` on decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DecodeKeys.self)
        id   = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)

        if let src = try c.decodeIfPresent(ServerSource.self, forKey: .source) {
            source = src
        } else if let legacyBonjour = try c.decodeIfPresent(Bool.self, forKey: .isBonjourDiscovered) {
            source = legacyBonjour ? .bonjour : .manual
        } else {
            source = .manual
        }
    }

    /// Canonical keys for encoding. The legacy `isBonjourDiscovered` key is handled
    /// only in `init(from:)` and is never written back.
    private enum EncodeKeys: String, CodingKey {
        case id, name, host, port, source, lastConnectedAt
    }

    /// Decode keys include the legacy field so we can migrate old UserDefaults data.
    private enum DecodeKeys: String, CodingKey {
        case id, name, host, port, source, lastConnectedAt
        case isBonjourDiscovered
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EncodeKeys.self)
        try c.encode(id,               forKey: .id)
        try c.encode(name,             forKey: .name)
        try c.encode(host,             forKey: .host)
        try c.encode(port,             forKey: .port)
        try c.encode(source,           forKey: .source)
        try c.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
    }

    // MARK: - Memberwise init (for tests / internal construction)

    init(id: String, name: String, host: String, port: Int,
         source: ServerSource = .manual, lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.source = source
        self.lastConnectedAt = lastConnectedAt
    }
}

struct TreeSummary: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let createdAt: Date
    let branchCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case branchCount = "branch_count"
    }
}

struct BranchSummary: Identifiable, Codable, Equatable {
    let id: String
    let treeId: String
    let name: String
    let messageCount: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case treeId = "tree_id"
        case name
        case messageCount = "message_count"
        case createdAt = "created_at"
    }
}

struct Message: Identifiable, Codable, Equatable {
    let id: String
    let role: String
    let content: String
    let index: Int
}
