import AppKit
import Foundation

/// Supported export formats for conversation branches.
enum BranchExportFormat: String, CaseIterable {
    case markdown
    case json
    case html

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        case .html: return "html"
        }
    }

    var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .html: return "HTML"
        }
    }

    var utType: String {
        switch self {
        case .markdown: return "net.daringfireball.markdown"
        case .json: return "public.json"
        case .html: return "public.html"
        }
    }
}

/// Exports conversation branches as Markdown, JSON, or HTML.
@MainActor
final class BranchExportService {
    static let shared = BranchExportService()

    private init() {}

    // MARK: - Public API

    /// Export branch content and copy to the system pasteboard.
    func copyToClipboard(branchId: String, format: BranchExportFormat) {
        do {
            let exported = try export(branchId: branchId, format: format)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(exported, forType: .string)
            wtLog("[BranchExport] Copied \(format.rawValue) to clipboard for branch \(branchId.prefix(8))")
        } catch {
            wtLog("[BranchExport] copyToClipboard failed: \(error)")
        }
    }

    /// Export branch content and present an NSSavePanel to write to disk.
    func saveToFile(branchId: String, format: BranchExportFormat) {
        do {
            let exported = try export(branchId: branchId, format: format)
            let branch = try TreeStore.shared.getBranch(branchId)
            let defaultName = sanitizeFilename(branch?.displayTitle ?? "branch-export")

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
            panel.allowedContentTypes = [.init(filenameExtension: format.fileExtension) ?? .plainText]
            panel.canCreateDirectories = true

            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try exported.write(to: url, atomically: true, encoding: .utf8)
                    wtLog("[BranchExport] Saved \(format.rawValue) to \(url.path)")
                } catch {
                    wtLog("[BranchExport] saveToFile write failed: \(error)")
                }
            }
        } catch {
            wtLog("[BranchExport] saveToFile export failed: \(error)")
        }
    }

    // MARK: - Export Rendering

    private func export(branchId: String, format: BranchExportFormat) throws -> String {
        guard let branch = try TreeStore.shared.getBranch(branchId),
              let sessionId = branch.sessionId else {
            throw ExportError.branchNotFound
        }

        let messages = try MessageStore.shared.getMessages(sessionId: sessionId, limit: 10000)

        switch format {
        case .markdown: return renderMarkdown(branch: branch, messages: messages)
        case .json: return renderJSON(branch: branch, messages: messages)
        case .html: return renderHTML(branch: branch, messages: messages)
        }
    }

    // MARK: - Markdown

    private func renderMarkdown(branch: Branch, messages: [Message]) -> String {
        var lines: [String] = []

        lines.append("# \(branch.displayTitle)")
        lines.append("")
        lines.append("**Type**: \(branch.branchType.rawValue.capitalized)")
        lines.append("**Status**: \(branch.status.rawValue.capitalized)")
        lines.append("**Created**: \(Self.dateFormatter.string(from: branch.createdAt))")
        lines.append("**Messages**: \(messages.count)")
        if let summary = branch.summary {
            lines.append("**Summary**: \(summary)")
        }
        lines.append("")
        lines.append("---")
        lines.append("")

        for msg in messages {
            let roleHeader: String
            switch msg.role {
            case .user:      roleHeader = "## You"
            case .assistant: roleHeader = "## Assistant"
            case .system:    roleHeader = "## System"
            }
            lines.append(roleHeader)
            lines.append("")
            lines.append(msg.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    private func renderJSON(branch: Branch, messages: [Message]) -> String {
        let messageObjects: [[String: String]] = messages.map { msg in
            [
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": Self.iso8601Formatter.string(from: msg.createdAt)
            ]
        }

        let payload: [String: Any] = [
            "branch": [
                "id": branch.id,
                "title": branch.displayTitle,
                "type": branch.branchType.rawValue,
                "status": branch.status.rawValue,
                "created_at": Self.iso8601Formatter.string(from: branch.createdAt),
                "updated_at": Self.iso8601Formatter.string(from: branch.updatedAt),
                "summary": branch.summary ?? NSNull()
            ] as [String: Any],
            "messages": messageObjects,
            "exported_at": Self.iso8601Formatter.string(from: Date()),
            "message_count": messages.count
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - HTML

    private func renderHTML(branch: Branch, messages: [Message]) -> String {
        var messageBlocks = ""
        for msg in messages {
            let (roleLabel, roleClass): (String, String)
            switch msg.role {
            case .user:      (roleLabel, roleClass) = ("You", "user")
            case .assistant: (roleLabel, roleClass) = ("Assistant", "assistant")
            case .system:    (roleLabel, roleClass) = ("System", "system")
            }
            let escapedContent = msg.content
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>\n")

            messageBlocks += """
                <div class="message \(roleClass)">
                    <div class="role">\(roleLabel)</div>
                    <div class="content">\(escapedContent)</div>
                </div>

                """
        }

        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>\(escapeHTML(branch.displayTitle))</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        max-width: 800px;
                        margin: 0 auto;
                        padding: 24px;
                        background: #1a1a2e;
                        color: #e0e0e0;
                    }
                    h1 { color: #7c9dff; margin-bottom: 4px; }
                    .meta { color: #888; font-size: 0.85em; margin-bottom: 24px; }
                    .message { margin-bottom: 16px; padding: 12px 16px; border-radius: 8px; }
                    .message.user { background: #1e3a5f; border-left: 3px solid #4a9eff; }
                    .message.assistant { background: #1e2d1e; border-left: 3px solid #4aff7c; }
                    .message.system { background: #2d2d1e; border-left: 3px solid #ffd74a; }
                    .role { font-weight: 600; font-size: 0.8em; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 6px; color: #aaa; }
                    .content { white-space: pre-wrap; line-height: 1.5; }
                    hr { border: none; border-top: 1px solid #333; margin: 24px 0; }
                </style>
            </head>
            <body>
                <h1>\(escapeHTML(branch.displayTitle))</h1>
                <div class="meta">
                    \(branch.branchType.rawValue.capitalized) · \(branch.status.rawValue.capitalized) · \(Self.dateFormatter.string(from: branch.createdAt)) · \(messages.count) messages
                </div>
                <hr>
                \(messageBlocks)
                <hr>
                <div class="meta">Exported from World Tree on \(Self.dateFormatter.string(from: Date()))</div>
            </body>
            </html>
            """
    }

    // MARK: - Helpers

    private func escapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func sanitizeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return String(cleaned.prefix(60))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    enum ExportError: LocalizedError {
        case branchNotFound

        var errorDescription: String? {
            switch self {
            case .branchNotFound: return "Branch not found or has no session."
            }
        }
    }
}
