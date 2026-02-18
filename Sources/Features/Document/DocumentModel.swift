import Foundation
import SwiftUI

/// Document-based conversation model (replaces discrete message bubbles)
struct ConversationDocument {
    var sections: [DocumentSection]
    var cursors: [Cursor]
    var metadata: DocumentMetadata
}

struct DocumentSection: Identifiable {
    let id: UUID
    var content: AttributedString
    var author: Author
    var timestamp: Date
    var branchPoint: Bool  // Can this section become a branch?
    var metadata: SectionMetadata
    var isEditable: Bool

    init(
        id: UUID = UUID(),
        content: AttributedString,
        author: Author,
        timestamp: Date = Date(),
        branchPoint: Bool = false,
        metadata: SectionMetadata = SectionMetadata(),
        isEditable: Bool = false
    ) {
        self.id = id
        self.content = content
        self.author = author
        self.timestamp = timestamp
        self.branchPoint = branchPoint
        self.metadata = metadata
        self.isEditable = isEditable
    }
}

enum Author: Equatable {
    case user(name: String)
    case assistant
    case system

    var displayName: String {
        switch self {
        case .user(let name): return name
        case .assistant: return "Cortana"
        case .system: return "System"
        }
    }

    var color: Color {
        switch self {
        case .user: return .blue
        case .assistant: return .purple
        case .system: return .gray
        }
    }
}

struct SectionMetadata {
    var toolCalls: [ToolCall]?
    var codeBlocks: [CodeBlock]?
    var attachments: [Attachment]?
    var tokens: TokenCount?
}

struct ToolCall: Identifiable {
    let id: UUID
    let name: String
    let input: String
    let output: String?
    let status: ToolStatus

    enum ToolStatus {
        case pending
        case running
        case success
        case error
    }
}

struct CodeBlock: Identifiable {
    let id: UUID
    var language: String
    var code: String
    var filePath: String?
    var isExecutable: Bool
}

struct Attachment: Identifiable {
    let id: UUID
    let type: AttachmentType
    let url: URL?
    let data: Data?

    enum AttachmentType {
        case image
        case file
        case link
    }
}

struct TokenCount {
    let input: Int
    let output: Int

    var total: Int { input + output }
}

struct Cursor: Identifiable {
    let id: UUID
    var position: Int  // Character offset in document
    var owner: Author
    var isActive: Bool
}

struct DocumentMetadata {
    var title: String?
    var project: String?
    var totalTokens: Int
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - Conversion Helpers

extension DocumentSection {
    /// Create a document section from a message
    static func from(message: Message) -> DocumentSection {
        let author: Author
        switch message.role {
        case .user:
            author = .user(name: "Evan")
        case .assistant:
            author = .assistant
        case .system:
            author = .system
        }

        var attributedContent = AttributedString(message.content)

        // Apply basic styling
        switch author {
        case .assistant:
            attributedContent.font = .system(.body)
        case .user:
            attributedContent.font = .system(.body)
            attributedContent.foregroundColor = .primary
        case .system:
            break
        }

        let isUser = if case .user = author { true } else { false }

        return DocumentSection(
            content: attributedContent,
            author: author,
            timestamp: message.timestamp,
            branchPoint: true,  // All sections can be branch points
            isEditable: isUser
        )
    }

}

