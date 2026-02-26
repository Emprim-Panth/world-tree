import Foundation

/// A unified event from any source in the Cortana ecosystem.
/// Used by the Timeline view to show a single chronological stream.
struct UnifiedTimelineEvent: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let eventType: EventType
    let project: String?
    let summary: String
    let metadata: [String: String]

    enum EventType: String, CaseIterable {
        case session = "session"
        case dispatch = "dispatch"
        case knowledgeAdd = "knowledge_add"
        case knowledgeUpdate = "knowledge_update"
        case archival = "archival"
        case crewDispatch = "crew_dispatch"
        case graphChange = "graph_change"

        var label: String {
            switch self {
            case .session: return "Session"
            case .dispatch: return "Dispatch"
            case .knowledgeAdd: return "Knowledge"
            case .knowledgeUpdate: return "Knowledge Update"
            case .archival: return "Archive"
            case .crewDispatch: return "Crew"
            case .graphChange: return "Graph"
            }
        }

        var icon: String {
            switch self {
            case .session: return "bubble.left.and.bubble.right"
            case .dispatch: return "arrow.right.circle"
            case .knowledgeAdd: return "brain"
            case .knowledgeUpdate: return "arrow.triangle.2.circlepath"
            case .archival: return "archivebox"
            case .crewDispatch: return "person.2"
            case .graphChange: return "point.3.connected.trianglepath.dotted"
            }
        }
    }
}
