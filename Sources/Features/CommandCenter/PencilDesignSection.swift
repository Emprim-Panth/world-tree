import SwiftUI

// MARK: - PencilDesignSection

/// Design tab section for the Command Center.
/// Shows live Pencil canvas state — connection, current file, frames, variables.
/// Hidden when pencil.feature.enabled is false (default).
struct PencilDesignSection: View {
    @ObservedObject private var pencil = PencilConnectionStore.shared
    @State private var selectedFrame: PencilNode?
    @State private var isShowingInspector = false
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader
            if pencil.isConnected {
                connectedContent
            } else {
                offlineEmptyState
            }
        }
        .onAppear { PencilConnectionStore.shared.startPolling() }
        .onDisappear { PencilConnectionStore.shared.stopPolling() }
        .sheet(isPresented: $isShowingInspector) {
            if let frame = selectedFrame {
                PencilFrameInspectorView(frame: frame)
            }
        }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            connectionPill
            Spacer()
            refreshButton
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil.circle\(pencil.isConnected ? ".fill" : "")")
                .font(.system(size: 9))
            Text(pencil.isConnected ? "Pencil connected" : "Pencil offline")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(pencil.isConnected ? Color.green : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pencil.isConnected ? "Pencil canvas connected" : "Pencil canvas offline")
    }

    private var refreshButton: some View {
        Button {
            Task {
                isRefreshing = true
                await pencil.refreshNow()
                isRefreshing = false
            }
        } label: {
            Image(systemName: isRefreshing ? "arrow.clockwise" : "arrow.clockwise")
                .font(.system(size: 11))
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .accessibilityLabel("Refresh Pencil canvas")
    }

    // MARK: - Connected Content

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = pencil.lastEditorState {
                editorStateRow(state)
            }
            if let layout = pencil.lastLayout, !layout.frames.isEmpty {
                frameList(layout.frames)
            }
            if !pencil.lastVariables.isEmpty {
                variablesSection(pencil.lastVariables)
            }
        }
    }

    private func editorStateRow(_ state: PencilEditorState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(state.currentFileName ?? "No file open")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(state.currentFileName != nil ? .primary : .secondary)
            Spacer()
            if !state.selectedNodeIds.isEmpty {
                Text("\(state.selectedNodeIds.count) selected")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }

    private func frameList(_ frames: [PencilNode]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FRAMES")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            ForEach(frames) { frame in
                PencilFrameRow(frame: frame) {
                    selectedFrame = frame
                    isShowingInspector = true
                }
            }
        }
    }

    private func variablesSection(_ vars: [PencilVariable]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOKENS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            ForEach(vars.prefix(6)) { variable in
                HStack(spacing: 6) {
                    if variable.type == .color {
                        colorSwatch(variable.value)
                    } else {
                        Image(systemName: "number")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                    Text(variable.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(variable.value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }

            if vars.count > 6 {
                Text("+ \(vars.count - 6) more tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
            }
        }
    }

    private func colorSwatch(_ hex: String) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(hex: hex) ?? .clear)
            .frame(width: 12, height: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }

    // MARK: - Offline Empty State

    private var offlineEmptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.slash")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pencil not running")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Start Pencil in your IDE to connect.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - PencilFrameRow

private struct PencilFrameRow: View {
    let frame: PencilNode
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: iconForType(frame.type))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text(frame.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if let w = frame.width, let h = frame.height {
                    Text("\(Int(w))×\(Int(h))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if let annotation = frame.annotation, !annotation.isEmpty {
                    Text(annotation)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(3)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(6)
        .accessibilityLabel("Frame: \(frame.displayName)")
    }

    private func iconForType(_ type: PencilNodeType) -> String {
        switch type {
        case .frame:     return "rectangle.dashed"
        case .component: return "puzzlepiece"
        case .group:     return "rectangle.3.group"
        case .text:      return "textformat"
        case .image:     return "photo"
        default:         return "square"
        }
    }
}

// MARK: - PencilFrameInspectorView

struct PencilFrameInspectorView: View {
    let frame: PencilNode
    /// Active project — used to query frame→ticket link. Optional; inspector works without it.
    var project: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var linkedTicket: Ticket? = nil
    @State private var isLoadingLink = true
    @State private var expandedNodeIds: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ticketLinkBanner
                    propertiesCard
                    if !frame.children.isEmpty {
                        nodeTreeSection(nodes: frame.children, depth: 0)
                    }
                }
                .padding()
            }
            .navigationTitle(frame.displayName)
            .navigationSubtitle(frame.type.rawValue.capitalized)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let ticket = linkedTicket {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            // Open the ticket — post notification so CommandCenter can navigate
                            NotificationCenter.default.post(
                                name: .pencilOpenTicket,
                                object: ticket.id
                            )
                            dismiss()
                        } label: {
                            Label("Open \(ticket.id)", systemImage: "ticket")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await resolveTicketLink() }
    }

    // MARK: - Ticket Link Banner

    @ViewBuilder
    private var ticketLinkBanner: some View {
        if isLoadingLink {
            EmptyView()
        } else if let ticket = linkedTicket {
            HStack(spacing: 10) {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ticket.id)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                    Text(ticket.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                Spacer()
                Text(ticket.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(4)
            }
            .padding(10)
            .background(Color.blue.opacity(0.07))
            .cornerRadius(8)
        } else if let annotation = frame.annotation {
            HStack(spacing: 8) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Annotated \"\(annotation)\" — ticket not found in this project")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.orange.opacity(0.07))
            .cornerRadius(8)
        }
    }

    // MARK: - Properties Card

    private var propertiesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROPERTIES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            propertyRow("ID", value: frame.id)
            propertyRow("Type", value: frame.type.rawValue)
            if let x = frame.x, let y = frame.y {
                propertyRow("Position", value: "(\(Int(x)), \(Int(y)))")
            }
            if let w = frame.width, let h = frame.height {
                propertyRow("Size", value: "\(Int(w)) × \(Int(h))")
            }
            if let fill = frame.fill {
                HStack {
                    Text("Fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: fill) ?? .clear)
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    Text(fill)
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                }
            }
            if let stroke = frame.stroke {
                propertyRow("Stroke", value: stroke)
            }
            propertyRow("Children", value: "\(frame.children.count)")
            if !frame.components.isEmpty {
                propertyRow("Components", value: frame.components.joined(separator: ", "))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func propertyRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    // MARK: - Node Tree

    private func nodeTreeSection(nodes: [PencilNode], depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 2) {
                if depth == 0 {
                    Text("NODE TREE (\(totalDescendants) nodes)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }
                ForEach(nodes) { node in
                    nodeRow(node: node, depth: depth)
                    if expandedNodeIds.contains(node.id), !node.children.isEmpty {
                        nodeTreeSection(nodes: node.children, depth: depth + 1)
                            .padding(.leading, 16)
                    }
                }
            }
        )
    }

    private func nodeRow(node: PencilNode, depth: Int) -> some View {
        Button {
            if !node.children.isEmpty {
                if expandedNodeIds.contains(node.id) {
                    expandedNodeIds.remove(node.id)
                } else {
                    expandedNodeIds.insert(node.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                // Expand chevron
                if !node.children.isEmpty {
                    Image(systemName: expandedNodeIds.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }

                Image(systemName: nodeIcon(node.type))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text(node.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !node.children.isEmpty {
                    Text("\(node.children.count)")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let w = node.width, let h = node.height {
                    Text("\(Int(w))×\(Int(h))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if let fill = node.fill {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: fill) ?? .clear)
                        .frame(width: 10, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(node.children.isEmpty ? 0 : 0.03))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private var totalDescendants: Int { frame.totalCount - 1 }

    private func nodeIcon(_ type: PencilNodeType) -> String {
        switch type {
        case .frame:     return "rectangle.dashed"
        case .component: return "puzzlepiece"
        case .group:     return "rectangle.3.group"
        case .text:      return "textformat"
        case .image:     return "photo"
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .line:      return "line.diagonal"
        case .path:      return "scribble"
        default:         return "square"
        }
    }

    // MARK: - Helpers

    private func resolveTicketLink() async {
        isLoadingLink = true
        defer { isLoadingLink = false }
        guard let annotation = frame.annotation, let project else { return }
        linkedTicket = await Task.detached {
            (try? await PenAssetStore.shared.frameLinksWithTickets(assetId: "").first(where: { $0.link.annotation == annotation })?.ticket)
            ?? TicketStore.shared.tickets(for: project).first(where: { $0.id == annotation })
        }.value
    }
}

// MARK: - Notification

extension Notification.Name {
    static let pencilOpenTicket = Notification.Name("pencilOpenTicket")
}

// MARK: - Color Hex Extension

private extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
