import SwiftUI

struct CortanaOpsSection: View {
    @ObservedObject var store: CortanaOpsStore = .shared

    var body: some View {
        if store.agentEvents.isEmpty && store.attentionItems.isEmpty && store.lastError == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let lastError = store.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !store.attentionItems.isEmpty {
                    attentionList
                }
                if !store.agentEvents.isEmpty {
                    eventList
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("CORTANA OPS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if !store.attentionItems.isEmpty {
                Text("\(store.attentionItems.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.orange))
            }
            Spacer()
            Button("Refresh") {
                Task { await store.refresh() }
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
    }

    private var attentionList: some View {
        VStack(spacing: 4) {
            ForEach(store.attentionItems.prefix(6)) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.priority == "high" ? "exclamationmark.triangle.fill" : "eye.fill")
                        .foregroundStyle(item.priority == "high" ? .orange : .blue)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.project ?? "Unknown Project")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(item.reason)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Resolve") {
                        store.resolveAttention(item)
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var eventList: some View {
        VStack(spacing: 4) {
            ForEach(store.agentEvents.prefix(8)) { event in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(color(for: event.severity))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.project ?? "Unknown Project")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("\(event.eventType): \(event.recommendedAction ?? "No recommendation")")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text("Confidence: \(event.confidence)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ack") {
                        store.resolve(event: event)
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func color(for severity: String) -> Color {
        switch severity {
        case "critical": .red
        case "warning": .orange
        default: .blue
        }
    }
}
