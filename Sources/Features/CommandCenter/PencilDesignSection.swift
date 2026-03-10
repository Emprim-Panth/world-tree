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

// MARK: - PencilFrameInspectorView (Phase 1 stub — full impl in TASK-076)

struct PencilFrameInspectorView: View {
    let frame: PencilNode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    frameProperties
                    if !frame.children.isEmpty {
                        childrenSection
                    }
                }
                .padding()
            }
            .navigationTitle(frame.displayName)
            .navigationSubtitle("Read only")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private var frameProperties: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROPERTIES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            propertyRow("Type", value: frame.type.rawValue)
            if let x = frame.x, let y = frame.y {
                propertyRow("Position", value: "(\(Int(x)), \(Int(y)))")
            }
            if let w = frame.width, let h = frame.height {
                propertyRow("Size", value: "\(Int(w)) × \(Int(h))")
            }
            if let fill = frame.fill {
                propertyRow("Fill", value: fill)
            }
            if let annotation = frame.annotation {
                propertyRow("Ticket", value: annotation)
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

    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHILDREN (\(frame.children.count))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(frame.children) { child in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(child.displayName)
                        .font(.system(size: 11))
                    Spacer()
                    Text(child.type.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(4)
            }
        }
    }
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
