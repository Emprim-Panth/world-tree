import Foundation

// MARK: - PencilDocument

/// Top-level .pen file document
struct PencilDocument: Codable, Sendable, Equatable {
    let version: String?
    let nodes: [PencilNode]

    init(version: String? = nil, nodes: [PencilNode] = []) {
        self.version = version
        self.nodes = nodes
    }

    /// All frame-type nodes, recursively flattened
    var allFrames: [PencilNode] {
        nodes.flatMap { $0.allFrames }
    }

    /// Total node count, recursively
    var totalNodeCount: Int {
        nodes.reduce(0) { $0 + $1.totalCount }
    }
}

// MARK: - PencilNode

/// A node in the .pen document tree
struct PencilNode: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let type: PencilNodeType
    let name: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let fill: String?
    let stroke: String?
    let annotation: String?     // Optional TASK-NNN reference for frame→ticket linking
    let children: [PencilNode]
    let components: [String]

    init(
        id: String,
        type: PencilNodeType = .unknown,
        name: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        fill: String? = nil,
        stroke: String? = nil,
        annotation: String? = nil,
        children: [PencilNode] = [],
        components: [String] = []
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fill = fill
        self.stroke = stroke
        self.annotation = annotation
        self.children = children
        self.components = components
    }

    /// Recursively collect all frame-type nodes
    var allFrames: [PencilNode] {
        var result: [PencilNode] = []
        if type == .frame { result.append(self) }
        result += children.flatMap { $0.allFrames }
        return result
    }

    /// Total node count including self and all descendants
    var totalCount: Int {
        1 + children.reduce(0) { $0 + $1.totalCount }
    }

    /// Display name — falls back to id if name is missing
    var displayName: String { name ?? id }

    enum CodingKeys: String, CodingKey {
        case id, type, name, x, y, width, height, fill, stroke, annotation, children, components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = (try? container.decode(PencilNodeType.self, forKey: .type)) ?? .unknown
        name = try? container.decode(String.self, forKey: .name)
        x = try? container.decode(Double.self, forKey: .x)
        y = try? container.decode(Double.self, forKey: .y)
        width = try? container.decode(Double.self, forKey: .width)
        height = try? container.decode(Double.self, forKey: .height)
        fill = try? container.decode(String.self, forKey: .fill)
        stroke = try? container.decode(String.self, forKey: .stroke)
        annotation = try? container.decode(String.self, forKey: .annotation)
        children = (try? container.decode([PencilNode].self, forKey: .children)) ?? []
        components = (try? container.decode([String].self, forKey: .components)) ?? []
    }
}

// MARK: - PencilNodeType

enum PencilNodeType: String, Codable, Sendable, Equatable {
    case frame
    case component
    case group
    case text
    case image
    case rectangle
    case ellipse
    case line
    case path
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = PencilNodeType(rawValue: raw) ?? .unknown
    }
}

// MARK: - PencilVariable

/// A design token / variable
struct PencilVariable: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let value: String
    let type: PencilVariableType?

    var id: String { name }

    enum PencilVariableType: String, Codable, Sendable, Equatable {
        case color, number, string, unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = (try? container.decode(String.self)) ?? ""
            self = PencilVariableType(rawValue: raw) ?? .unknown
        }
    }
}

// MARK: - PencilViewport

struct PencilViewport: Codable, Sendable, Equatable {
    let x: Double?
    let y: Double?
    let zoom: Double?
}

// MARK: - PencilLayout

/// Response from snapshot_layout — the canvas layout state
struct PencilLayout: Codable, Sendable, Equatable {
    let frames: [PencilNode]
    let viewport: PencilViewport?

    static let empty = PencilLayout(frames: [], viewport: nil)
}

// MARK: - PencilEditorState

/// Response from get_editor_state — the current selection and file
struct PencilEditorState: Codable, Sendable, Equatable {
    let currentFile: String?
    let selectedNodeIds: [String]
    let zoom: Double?

    static let empty = PencilEditorState(currentFile: nil, selectedNodeIds: [], zoom: nil)

    /// Filename only, not full path
    var currentFileName: String? {
        guard let path = currentFile else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case currentFile = "current_file"
        case selectedNodeIds = "selected_node_ids"
        case zoom
    }

    init(currentFile: String?, selectedNodeIds: [String], zoom: Double?) {
        self.currentFile = currentFile
        self.selectedNodeIds = selectedNodeIds
        self.zoom = zoom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentFile = try? container.decode(String.self, forKey: .currentFile)
        selectedNodeIds = (try? container.decode([String].self, forKey: .selectedNodeIds)) ?? []
        zoom = try? container.decode(Double.self, forKey: .zoom)
    }
}

// MARK: - PencilBatchResult

/// Response from batch_design operations
struct PencilBatchResult: Codable, Sendable, Equatable {
    let success: Bool
    let applied: Int
    let errors: [String]
}
