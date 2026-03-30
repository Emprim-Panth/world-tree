import SwiftUI

/// Displays local model status, routing stats, brain index health,
/// and recent escalations in the Command Center.
struct IntelligenceDashboard: View {
    var router = QualityRouter.shared
    var indexer = BrainIndexer.shared
    @State private var models: [QualityRouter.ModelStatus] = []
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    modelStatusRow
                    Divider()
                    routingStatsRow
                    Divider()
                    brainIndexRow
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.purple.opacity(0.2), lineWidth: 1))
        .onAppear {
            Task {
                models = await router.loadedModels()
                router.refreshStats()
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(.purple)
            Text("Local Intelligence").font(.system(size: 11, weight: .semibold))

            Spacer()

            // Quick stats inline
            if !isExpanded {
                if !models.isEmpty {
                    Text("\(models.count) models")
                        .font(.system(size: 9)).foregroundStyle(.green)
                }
                if router.todayStats.totalCount > 0 {
                    Text("\(router.todayStats.localPercent)% local")
                        .font(.system(size: 9)).foregroundStyle(.cyan)
                }
                if indexer.chunkCount > 0 {
                    Text("\(indexer.chunkCount) chunks")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    // MARK: - Models

    private var modelStatusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "memorychip").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("Models").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { models = await router.loadedModels() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 8))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }

            if !router.ollamaOnline {
                HStack(spacing: 4) {
                    Circle().fill(Palette.error).frame(width: 6, height: 6)
                    Text("Ollama offline — local inference unavailable")
                        .font(.system(size: 9)).foregroundStyle(Palette.error)
                }
            } else if models.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(Palette.warning).frame(width: 6, height: 6)
                    Text("No models loaded — Ollama may be starting")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(models, id: \.name) { model in
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(model.name)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(model.size)
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Routing

    private var routingStatsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("Today's Routing").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }

            let stats = router.todayStats
            if stats.totalCount == 0 {
                Text("No inference requests today")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 16) {
                    statBadge("Local", "\(stats.localCount)", Palette.success)
                    statBadge("Claude", "\(stats.claudeCount)", Palette.info)
                    statBadge("Escalated", "\(stats.escalationCount)", Palette.warning)
                    statBadge("Local %", "\(stats.localPercent)%", stats.localPercent > 80 ? Palette.success : Palette.warning)
                }
            }
        }
    }

    private func statBadge(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(color)
            Text(label).font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Brain Index

    private var brainIndexRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("Brain Index").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if indexer.isIndexing {
                    ProgressView().controlSize(.mini)
                    Text("Indexing...").font(.system(size: 8)).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("\(indexer.chunkCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text("chunks")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if let lastIndex = indexer.lastIndexDate {
                    HStack(spacing: 4) {
                        Text("Last:")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(lastIndex, style: .relative)
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Reindex") {
                    Task { await indexer.indexAll() }
                }
                .font(.system(size: 9))
                .buttonStyle(.bordered).controlSize(.mini)
            }
        }
    }
}
