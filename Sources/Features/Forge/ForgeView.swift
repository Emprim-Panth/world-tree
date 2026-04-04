import SwiftUI

/// The Forge — unified file browser for ~/.cortana/.
/// HSplitView: left side is bookmarks + file tree; right side is content viewer/editor.
struct ForgeView: View {
    @State private var store = ForgeStore.shared
    @State private var scrollProxy: ScrollViewProxy? = nil

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            contentPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.refresh()
        }
        .alert("Delete Item", isPresented: $store.showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let url = store.pendingDeleteURL {
                    store.trash(url: url)
                }
                store.pendingDeleteURL = nil
            }
            Button("Cancel", role: .cancel) {
                store.pendingDeleteURL = nil
            }
        } message: {
            if let url = store.pendingDeleteURL {
                Text("Move '\(url.lastPathComponent)' to Trash? This cannot be undone from here.")
            }
        }
        .alert("Error", isPresented: $store.showError) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "An unknown error occurred.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            bookmarkBar
            Divider()
            fileTree
        }
        .background(Palette.cardBackground)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.accent)
            Text("The Forge")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Bookmark Bar

    private var bookmarkBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.bookmarks) { bookmark in
                    bookmarkButton(bookmark)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func bookmarkButton(_ bookmark: ForgeBookmark) -> some View {
        Button {
            navigateTo(bookmark)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: bookmark.icon)
                    .font(.system(size: 10))
                Text(bookmark.name)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.accent.opacity(0.1))
            .foregroundStyle(Palette.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Jump to \(bookmark.name)")
    }

    // MARK: - File Tree

    private var fileTree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForgeFileTree(store: store, nodes: store.rootNodes)
                }
                .padding(6)
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    // MARK: - Content Pane

    @ViewBuilder
    private var contentPane: some View {
        if store.isEditing {
            ForgeEditorView(store: store)
        } else if let url = store.selectedURL {
            ForgeContentView(store: store, url: url)
        } else {
            emptyState
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 48))
                .foregroundStyle(Palette.accent.opacity(0.3))
            Text("The Forge")
                .font(.title2.bold())
                .foregroundStyle(.secondary)
            Text("Browse and edit files in ~/.cortana/\nSelect a file from the tree to view its contents.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation

    private func navigateTo(_ bookmark: ForgeBookmark) {
        let targetURL = store.url(for: bookmark)
        store.navigate(to: targetURL)
    }
}

// MARK: - ForgeContentView

/// Read-only viewer for a selected file. Shows text content or metadata for binary/db files.
struct ForgeContentView: View {
    var store: ForgeStore
    let url: URL

    private var isTextFile: Bool {
        let ext = url.pathExtension.lowercased()
        return ["md", "yaml", "yml", "json", "txt", "toml", "sh", "py", "swift", "log", "conf", "cfg", "env"].contains(ext)
    }

    private var isBinaryFile: Bool {
        let ext = url.pathExtension.lowercased()
        return ["db", "sqlite", "png", "jpg", "jpeg", "gif", "pdf"].contains(ext)
    }

    var body: some View {
        VStack(spacing: 0) {
            contentHeader
            Divider()

            if isBinaryFile || store.selectedContent == nil && !isTextFile {
                metadataView
            } else if let content = store.selectedContent {
                textView(content)
            } else {
                loadingOrEmpty
            }
        }
    }

    // MARK: - Header

    private var contentHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon)
                .font(.system(size: 12))
                .foregroundStyle(Palette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    store.revealInFinder(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder")

                if isTextFile && store.selectedContent != nil {
                    Button {
                        store.beginEdit()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                            Text("Edit")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.cardBackground)
    }

    // MARK: - Text View

    private func textView(_ content: String) -> some View {
        ScrollView {
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.codeBackground)
    }

    // MARK: - Metadata View (for .db and binary files)

    private var metadataView: some View {
        VStack(alignment: .leading, spacing: 16) {
            let attrs = fileAttributes

            Group {
                metaRow("Path", value: url.path)
                metaRow("Size", value: attrs.size)
                metaRow("Modified", value: attrs.modified)
                metaRow("Type", value: url.pathExtension.uppercased())
            }

            Divider()

            HStack {
                Button("Reveal in Finder") {
                    store.revealInFinder(url)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var fileAttributes: (size: String, modified: String) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return ("unknown", "unknown")
        }
        let size: String
        if let bytes = attrs[.size] as? Int {
            size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            size = "unknown"
        }
        let modified: String
        if let date = attrs[.modificationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            modified = fmt.string(from: date)
        } else {
            modified = "unknown"
        }
        return (size, modified)
    }

    // MARK: - Loading / Empty

    private var loadingOrEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Cannot display file")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var fileIcon: String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md":           return "doc.text.fill"
        case "yaml", "yml":  return "gearshape.fill"
        case "json":         return "curlybraces"
        case "db", "sqlite": return "cylinder.fill"
        case "sh":           return "terminal.fill"
        default:             return "doc.fill"
        }
    }
}
