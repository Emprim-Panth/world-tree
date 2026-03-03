import ActivityKit

/// Shared Live Activity attributes — defined here so both the main app and Widget extension
/// can reference the type without a circular dependency.
struct WorldTreeActivityAttributes: ActivityAttributes {

    let treeName: String
    let branchName: String?

    struct ContentState: Codable, Hashable {
        var streamingText: String
        var isStreaming: Bool
    }
}
