import SwiftUI

/// Context window inspector and management
struct ContextInspectorView: View {
    @StateObject private var viewModel: ContextInspectorViewModel

    init(sessionId: String) {
        _viewModel = StateObject(wrappedValue: ContextInspectorViewModel(sessionId: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Context gauge header
            contextGaugeSection

            Divider()

            // Section list with pinning
            List {
                ForEach(viewModel.sections) { section in
                    ContextSectionRow(
                        section: section,
                        onTogglePin: {
                            viewModel.togglePin(section.id)
                        },
                        onDelete: {
                            viewModel.deleteSection(section.id)
                        }
                    )
                }
            }
            .listStyle(.inset)

            Divider()

            // Controls
            HStack {
                Button("Compact Now") {
                    viewModel.compactNow()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Auto-Compact: \(viewModel.autoCompactEnabled ? "ON" : "OFF")") {
                    viewModel.toggleAutoCompact()
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(minWidth: 400, idealWidth: 500)
        .onAppear {
            viewModel.loadSections()
        }
    }

    private var contextGaugeSection: some View {
        VStack(spacing: 12) {
            // Circular gauge
            ContextGaugeView(
                current: viewModel.currentTokens,
                max: viewModel.maxTokens,
                threshold: viewModel.rotationThreshold
            )

            // Stats
            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("\(viewModel.currentTokens.formatted())")
                        .font(.title2.monospacedDigit().bold())
                    Text("Current")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("\(viewModel.pinnedTokens.formatted())")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundColor(.blue)
                    Text("Pinned")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("\(viewModel.availableTokens.formatted())")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundColor(.green)
                    Text("Available")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Rotation threshold slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Rotation Threshold: \(Int(viewModel.thresholdPercentage))%")
                    .font(.caption.bold())

                Slider(value: $viewModel.thresholdPercentage, in: 50...95, step: 5)
                    .tint(.orange)

                Text("Context will rotate when reaching \(viewModel.rotationThreshold.formatted()) tokens")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }
}

@MainActor
class ContextInspectorViewModel: ObservableObject {
    @Published var sections: [ContextSection] = []
    @Published var currentTokens: Int = 0
    @Published var maxTokens: Int = 200_000
    @Published var thresholdPercentage: Double = 75.0
    @Published var autoCompactEnabled: Bool = true

    private let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    var rotationThreshold: Int {
        Int(Double(maxTokens) * (thresholdPercentage / 100.0))
    }

    var pinnedTokens: Int {
        sections.filter { $0.isPinned }.reduce(0) { $0 + $1.tokenCount }
    }

    var availableTokens: Int {
        max(0, maxTokens - currentTokens)
    }

    func loadSections() {
        // TODO: Load actual sections from session
        // For now, create sample sections
        let samples = [
            ContextSection(
                id: UUID(),
                title: "Initial prompt",
                content: "System instructions and initial context",
                tokenCount: 1500,
                timestamp: Date().addingTimeInterval(-3600),
                isPinned: true,
                canDelete: false
            ),
            ContextSection(
                id: UUID(),
                title: "Phase 1 discussion",
                content: "Gateway integration planning",
                tokenCount: 2500,
                timestamp: Date().addingTimeInterval(-2400),
                isPinned: false,
                canDelete: true
            ),
            ContextSection(
                id: UUID(),
                title: "Code implementation",
                content: "Multiple file changes and discussion",
                tokenCount: 8500,
                timestamp: Date().addingTimeInterval(-1200),
                isPinned: true,
                canDelete: false
            ),
            ContextSection(
                id: UUID(),
                title: "Recent conversation",
                content: "Current discussion about voice",
                tokenCount: 3200,
                timestamp: Date(),
                isPinned: false,
                canDelete: true
            )
        ]

        sections = samples
        currentTokens = samples.reduce(0) { $0 + $1.tokenCount }
    }

    func togglePin(_ sectionId: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[index].isPinned.toggle()
    }

    func deleteSection(_ sectionId: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == sectionId }),
              sections[index].canDelete else { return }

        let tokenCount = sections[index].tokenCount
        sections.remove(at: index)
        currentTokens -= tokenCount
    }

    func compactNow() {
        // Remove unpinned sections, oldest first
        let unpinned = sections.filter { !$0.isPinned && $0.canDelete }
            .sorted { $0.timestamp < $1.timestamp }

        var tokensFreed = 0
        let targetTokens = Int(Double(maxTokens) * 0.6) // Compact to 60%

        for section in unpinned {
            if currentTokens - tokensFreed <= targetTokens {
                break
            }

            if let index = sections.firstIndex(where: { $0.id == section.id }) {
                tokensFreed += sections[index].tokenCount
                sections.remove(at: index)
            }
        }

        currentTokens -= tokensFreed
    }

    func toggleAutoCompact() {
        autoCompactEnabled.toggle()
    }
}

// MARK: - Context Gauge

struct ContextGaugeView: View {
    let current: Int
    let max: Int
    let threshold: Int

    var body: some View {
        Gauge(value: Double(current), in: 0...Double(max)) {
            Text("Context")
        } currentValueLabel: {
            Text("\(Int(percentage))%")
                .font(.system(.title3, design: .rounded).monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(gaugeGradient)
        .scaleEffect(1.5)
    }

    private var percentage: Double {
        (Double(current) / Double(max)) * 100
    }

    private var gaugeGradient: LinearGradient {
        if percentage >= 90 {
            return LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
        } else if percentage >= 75 {
            return LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [.green, .blue], startPoint: .leading, endPoint: .trailing)
        }
    }
}

// MARK: - Context Section Row

struct ContextSectionRow: View {
    let section: ContextSection
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Pin button
            Button(action: onTogglePin) {
                Image(systemName: section.isPinned ? "pin.fill" : "pin.slash")
                    .foregroundColor(section.isPinned ? .blue : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help(section.isPinned ? "Unpin section" : "Pin section")

            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.subheadline.bold())

                Text(section.content)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label("\(section.tokenCount.formatted()) tokens", systemImage: "number")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(section.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if section.canDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Delete section")
            }
        }
        .padding(.vertical, 4)
        .opacity(section.isPinned ? 1.0 : 0.7)
    }
}

// MARK: - Models

struct ContextSection: Identifiable {
    let id: UUID
    var title: String
    var content: String
    var tokenCount: Int
    var timestamp: Date
    var isPinned: Bool
    var canDelete: Bool
}

// MARK: - View Extension

extension View {
    /// Add context inspector sheet
    func contextInspector(sessionId: String, isPresented: Binding<Bool>) -> some View {
        self.sheet(isPresented: isPresented) {
            ContextInspectorView(sessionId: sessionId)
        }
    }
}
