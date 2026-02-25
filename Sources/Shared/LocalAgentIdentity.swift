import Foundation

/// Cortana's identity — fixed, not read from any external file.
enum LocalAgentIdentity {
    static let name: String = "Cortana"

    /// First character of the name — used as the avatar initial.
    static var initial: String { String(name.prefix(1).uppercased()) }

    /// Sign-off emoji appended to assistant replies when appropriate.
    static var signOff: String { "💠" }
}
