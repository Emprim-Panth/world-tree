import SwiftUI

/// Full-screen output inspector for jobs and dispatches.
///
/// Shows live-streaming output for running tasks and completed output for
/// historical ones. Includes search, copy-to-clipboard, and auto-scroll.
struct JobOutputInspectorView: View {
    let entry: JobOutputStreamStore.OutputEntry
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var showLineNumbers = false
    @State private var pageSize = 500 // lines per page
    @State private var currentPage = 0

    private var outputLines: [String] {
        let text = entry.output
        if text.isEmpty { return [] }
        return text.components(separatedBy: "\n")
    }

    private var filteredLines: [(offset: Int, line: String)] {
        let lines = outputLines.enumerated().map { (offset: $0.offset, line: $0.element) }
        if searchText.isEmpty { return lines }
        let query = searchText.lowercased()
        return lines.filter { $0.line.lowercased().contains(query) }
    }

    private var totalPages: Int {
        max(1, (filteredLines.count + pageSize - 1) / pageSize)
    }

    private var visibleLines: [(offset: Int, line: String)] {
        let start = currentPage * pageSize
        let end = min(start + pageSize, filteredLines.count)
        guard start < filteredLines.count else { return [] }
        return Array(filteredLines[start..<end])
    }

    private var matchCount: Int {
        guard !searchText.isEmpty else { return 0 }
        return filteredLines.count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            outputContent
            if totalPages > 1 {
                Divider()
                paginationBar
            }
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 600)
        .background(Color(NSColor.textBackgroundColor))
        .onChange(of: entry.output) {
            // Auto-scroll to last page when new content arrives
            if autoScroll {
                currentPage = max(0, totalPages - 1)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // Status indicator
                statusBadge

                // Title
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.kind == .dispatch ? "Dispatch Output" : "Job Output")
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Project badge
                if let project = entry.project {
                    Text(project)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.8))
                        .clipShape(Capsule())
                }

                // Duration
                Text(formatDuration(since: entry.startedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                // Line count
                Text("\(outputLines.count) lines")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                // Copy button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.output, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .help("Copy all output")
                .accessibilityLabel("Copy output to clipboard")

                // Line numbers toggle
                Button {
                    showLineNumbers.toggle()
                } label: {
                    Image(systemName: "list.number")
                        .font(.system(size: 11))
                        .foregroundStyle(showLineNumbers ? .primary : .tertiary)
                }
                .buttonStyle(.bordered)
                .help("Toggle line numbers")

                // Auto-scroll toggle (only for live streams)
                if !entry.isComplete {
                    Button {
                        autoScroll.toggle()
                        if autoScroll {
                            currentPage = max(0, totalPages - 1)
                        }
                    } label: {
                        Image(systemName: autoScroll ? "arrow.down.to.line" : "arrow.down.to.line")
                            .font(.system(size: 11))
                            .foregroundStyle(autoScroll ? Color.green : Color.gray)
                    }
                    .buttonStyle(.bordered)
                    .help(autoScroll ? "Auto-scroll enabled" : "Auto-scroll disabled")
                }

                // Close
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close inspector")
            }

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                TextField("Search output...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !searchText.isEmpty {
                    Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        Group {
            switch entry.status {
            case "running":
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 10, height: 10)
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())

            case "completed":
                Label("DONE", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())

            case "failed":
                Label("FAILED", systemImage: "xmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())

            case "cancelled":
                Label("CANCELLED", systemImage: "stop.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())

            default:
                Text(entry.status.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Output Content

    private var outputContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entry.output.isEmpty && !entry.isComplete {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Waiting for output...")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else if entry.output.isEmpty && entry.isComplete {
                        HStack {
                            Spacer()
                            Text("No output captured")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else {
                        ForEach(visibleLines, id: \.offset) { item in
                            outputLine(lineNumber: item.offset + 1, text: item.line)
                                .id(item.offset)
                        }
                    }

                    // Error section
                    if let error = entry.error, !error.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Divider()
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                                Text("Error")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.red)
                            }
                            .padding(.top, 4)

                            Text(error)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.9))
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }

                    // Bottom anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 4)
            }
            .onChange(of: entry.output.count) {
                if autoScroll {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func outputLine(lineNumber: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if showLineNumbers {
                Text("\(lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 8)
            }

            Group {
                if !searchText.isEmpty {
                    highlightedText(text, query: searchText)
                } else {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.9))
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0.5)
        .background(lineNumber % 2 == 0 ? Color.primary.opacity(0.02) : Color.clear)
    }

    /// Highlight search matches within a line
    private func highlightedText(_ text: String, query: String) -> some View {
        let lower = text.lowercased()
        let queryLower = query.lowercased()
        var result = Text("")
        var searchRange = lower.startIndex

        while let range = lower.range(of: queryLower, range: searchRange..<lower.endIndex) {
            // Text before match
            let beforeRange = text[searchRange..<range.lowerBound]
            result = result + Text(beforeRange)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary.opacity(0.9))

            // Matched text — use Text-compatible modifiers only (no .background)
            let matchRange = text[range.lowerBound..<range.upperBound]
            result = result + Text(matchRange)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.yellow)
                .bold()
                .underline()

            searchRange = range.upperBound
        }

        // Remaining text
        if searchRange < text.endIndex {
            let remaining = text[searchRange..<text.endIndex]
            result = result + Text(remaining)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary.opacity(0.9))
        }

        return result.textSelection(.enabled)
    }

    // MARK: - Pagination

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Button {
                currentPage = max(0, currentPage - 1)
                autoScroll = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10))
            }
            .disabled(currentPage == 0)
            .buttonStyle(.plain)

            Text("Page \(currentPage + 1) of \(totalPages)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                currentPage = min(totalPages - 1, currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
            }
            .disabled(currentPage >= totalPages - 1)
            .buttonStyle(.plain)

            Spacer()

            // Page size selector
            Picker("Lines per page", selection: $pageSize) {
                Text("250").tag(250)
                Text("500").tag(500)
                Text("1000").tag(1000)
                Text("All").tag(Int.max)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .onChange(of: pageSize) {
                currentPage = 0
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    private func formatDuration(since start: Date) -> String {
        let d = Date().timeIntervalSince(start)
        if d < 60 { return "\(Int(d))s" }
        if d < 3600 { return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(d / 3600))h \(Int((d.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }
}
