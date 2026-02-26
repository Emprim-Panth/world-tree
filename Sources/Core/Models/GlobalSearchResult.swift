import Foundation

/// A search result from any FTS index in the system.
struct GlobalSearchResult: Identifiable, Hashable {
    let id: String
    let source: Source
    let title: String
    let snippet: String
    let project: String?
    let timestamp: Date?

    enum Source: String, CaseIterable {
        case message = "Messages"
        case knowledge = "Knowledge"
        case archive = "Archives"
        case graph = "Graph"

        var icon: String {
            switch self {
            case .message:   return "bubble.left.and.bubble.right"
            case .knowledge: return "brain"
            case .archive:   return "archivebox"
            case .graph:     return "point.3.connected.trianglepath.dotted"
            }
        }

        var color: String {
            switch self {
            case .message:   return "blue"
            case .knowledge: return "purple"
            case .archive:   return "green"
            case .graph:     return "pink"
            }
        }
    }
}
