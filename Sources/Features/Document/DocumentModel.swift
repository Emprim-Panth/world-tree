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
    var branchPoint: Bool       // Can this section become a branch?
    var metadata: SectionMetadata
    var isEditable: Bool
    var messageId: String?      // DB message ID — nil for streaming/optimistic sections
    var hasBranches: Bool       // True when child branches fork from this message
    var isFinding: Bool         // Content starts with "[Finding from branch"
    var hasFindingSignal: Bool  // Scanner detected signal words post-response

    init(
        id: UUID = UUID(),
        content: AttributedString,
        author: Author,
        timestamp: Date = Date(),
        branchPoint: Bool = false,
        metadata: SectionMetadata = SectionMetadata(),
        isEditable: Bool = false,
        messageId: String? = nil,
        hasBranches: Bool = false,
        isFinding: Bool = false,
        hasFindingSignal: Bool = false
    ) {
        self.id = id
        self.content = content
        self.author = author
        self.timestamp = timestamp
        self.branchPoint = branchPoint
        self.metadata = metadata
        self.isEditable = isEditable
        self.messageId = messageId
        self.hasBranches = hasBranches
        self.isFinding = isFinding
        self.hasFindingSignal = hasFindingSignal
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
    let filename: String
    let mimeType: String
    let data: Data

    enum AttachmentType {
        case image
        case file

        var systemImage: String {
            switch self {
            case .image: return "photo"
            case .file: return "doc"
            }
        }
    }

    /// Base64-encoded data for the Anthropic API.
    var base64: String { data.base64EncodedString() }

    /// NSImage from raw data (images only).
    var nsImage: NSImage? {
        guard type == .image else { return nil }
        return NSImage(data: data)
    }

    /// Build from a file URL — reads data, determines type from extension.
    static func from(url: URL) -> Attachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"]
        let isImage = imageExts.contains(ext)
        let mimeType: String
        switch ext {
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png":         mimeType = "image/png"
        case "gif":         mimeType = "image/gif"
        case "webp":        mimeType = "image/webp"
        case "pdf":         mimeType = "application/pdf"
        default:            mimeType = "application/octet-stream"
        }
        return Attachment(
            id: UUID(),
            type: isImage ? .image : .file,
            filename: url.lastPathComponent,
            mimeType: mimeType,
            data: data
        )
    }

    /// Build from raw image data (clipboard paste / drag NSImage).
    static func from(imageData: Data, filename: String = "image.png") -> Attachment {
        let isPNG = imageData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        let mime = isPNG ? "image/png" : "image/jpeg"
        return Attachment(
            id: UUID(),
            type: .image,
            filename: filename,
            mimeType: mime,
            data: imageData
        )
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

