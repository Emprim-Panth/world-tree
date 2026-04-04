import SwiftUI

/// Recursive file tree component for the Forge browser.
/// Renders a flat list of FileNodes with expand/collapse for directories,
/// single-click selection, and right-click context menus.
struct ForgeFileTree: View {
    @Bindable var store: ForgeStore
    var nodes: [FileNode]
    var depth: Int = 0

    var body: some View {
        ForEach(nodes) { node in
            ForgeFileRow(store: store, node: node, depth: depth)

            if node.isDirectory && node.isExpanded, let children = node.children {
                ForgeFileTree(store: store, nodes: children, depth: depth + 1)
            }
        }
    }
}

// MARK: - ForgeFileRow

struct ForgeFileRow: View {
    var store: ForgeStore
    var node: FileNode
    var depth: Int

    @State private var isHovered: Bool = false
    @State private var showNewFile: Bool = false
    @State private var showNewFolder: Bool = false
    @State private var newItemName: String = ""
    @State private var showRename: Bool = false
    @State private var renameText: String = ""

    private var isSelected: Bool {
        store.selectedURL == node.url
    }

    var body: some View {
        HStack(spacing: 4) {
            // Indentation
            Spacer().frame(width: CGFloat(depth) * 14)

            // Disclosure triangle for directories
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .animation(.easeInOut(duration: 0.15), value: node.isExpanded)
            } else {
                Spacer().frame(width: 12)
            }

            // Icon
            Image(systemName: node.icon)
                .font(.system(size: 11))
                .foregroundStyle(nodeColor)
                .frame(width: 14)

            // Name
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))

            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if node.isDirectory {
                if node.isExpanded {
                    store.collapse(node)
                } else {
                    store.expand(node)
                }
            }
            store.select(node)
        }
        .contextMenu { contextMenu }
        .sheet(isPresented: $showNewFile) {
            newItemSheet(isFile: true)
        }
        .sheet(isPresented: $showNewFolder) {
            newItemSheet(isFile: false)
        }
        .sheet(isPresented: $showRename) {
            renameSheet
        }
    }

    // MARK: - Background

    private var rowBackground: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Palette.accent.opacity(0.2))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Node color

    private var nodeColor: Color {
        switch node.colorTag {
        case .cyan:      return Palette.accent
        case .blue:      return Palette.info
        case .orange:    return Palette.warning
        case .yellow:    return .yellow
        case .purple:    return Palette.claude
        case .green:     return Palette.success
        case .secondary: return .secondary
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenu: some View {
        Button("Reveal in Finder") {
            store.revealInFinder(node.url)
        }

        Divider()

        if node.isDirectory {
            Button("New File…") {
                newItemName = ""
                showNewFile = true
            }
            Button("New Folder…") {
                newItemName = ""
                showNewFolder = true
            }
            Divider()
        }

        Button("Rename…") {
            renameText = node.name
            showRename = true
        }

        Divider()

        Button("Delete", role: .destructive) {
            store.pendingDeleteURL = node.url
            store.showDeleteConfirm = true
        }
    }

    // MARK: - Sheets

    private func newItemSheet(isFile: Bool) -> some View {
        VStack(spacing: 16) {
            Text(isFile ? "New File" : "New Folder")
                .font(.headline)
            TextField(isFile ? "filename.md" : "folder-name", text: $newItemName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitNew(isFile: isFile) }
            HStack {
                Button("Cancel") { isFile ? (showNewFile = false) : (showNewFolder = false) }
                Button(isFile ? "Create File" : "Create Folder") { commitNew(isFile: isFile) }
                    .buttonStyle(.borderedProminent)
                    .disabled(newItemName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func commitNew(isFile: Bool) {
        let name = newItemName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let targetDir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        if isFile {
            store.createFile(named: name, in: targetDir)
            showNewFile = false
        } else {
            store.createDirectory(named: name, in: targetDir)
            showNewFolder = false
        }
        newItemName = ""
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename")
                .font(.headline)
            TextField("New name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRename() }
            HStack {
                Button("Cancel") { showRename = false }
                Button("Rename") { commitRename() }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != node.name else { showRename = false; return }
        store.rename(url: node.url, to: name)
        showRename = false
    }
}
