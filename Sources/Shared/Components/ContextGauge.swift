import SwiftUI

// MARK: - Context Window Gauge

/// Visual indicator showing context window usage as a percentage.
/// Color-coded by pressure level: green → yellow → orange → red.
struct ContextGauge: View {
    let usage: Double  // 0.0 to 1.0
    let label: String
    var estimatedTokens: Int?
    var rotationCount: Int?

    init(usage: Double, label: String = "Context", estimatedTokens: Int? = nil, rotationCount: Int? = nil) {
        self.usage = min(max(usage, 0), 1)
        self.label = label
        self.estimatedTokens = estimatedTokens
        self.rotationCount = rotationCount
    }

    private var color: Color {
        if usage >= 0.90 { return .red }
        if usage >= 0.75 { return .orange }
        if usage >= 0.50 { return .yellow }
        return .green
    }

    private var percentText: String {
        "\(Int(usage * 100))%"
    }

    private var helpText: String {
        var text = "\(label): \(percentText) used"
        if let tokens = estimatedTokens {
            text += " (~\(formatTokenCount(tokens)) tokens)"
        }
        if let rotations = rotationCount, rotations > 0 {
            text += " | \(rotations) rotation\(rotations == 1 ? "" : "s")"
        }
        return text
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            return "\(count / 1000)K"
        }
        return "\(count)"
    }

    var body: some View {
        HStack(spacing: 4) {
            // Mini bar gauge
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.8))
                        .frame(width: geo.size.width * usage)
                }
            }
            .frame(width: 40, height: 6)

            Text(percentText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(color)

            // Rotation indicator
            if let rotations = rotationCount, rotations > 0 {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
        .help(helpText)
    }
}

/// Compact inline context gauge for header bars — just the bar + percentage.
struct InlineContextGauge: View {
    let inputTokens: Int
    let maxTokens: Int

    private var usage: Double {
        guard maxTokens > 0 else { return 0 }
        return Double(inputTokens) / Double(maxTokens)
    }

    var body: some View {
        ContextGauge(usage: usage, label: "Context window")
    }
}

// MARK: - Activity Pulse

/// Colored dot that pulses based on recent activity density.
/// Green = active, yellow = moderate, gray = idle.
struct ActivityPulse: View {
    let eventCount: Int
    let isResponding: Bool

    private var color: Color {
        if isResponding { return .green }
        if eventCount > 10 { return .green }
        if eventCount > 3 { return .yellow }
        if eventCount > 0 { return .blue }
        return .gray
    }

    private var shouldPulse: Bool {
        isResponding || eventCount > 5
    }

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(shouldPulse && isPulsing ? 0.4 : 1.0)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                isPulsing = shouldPulse
            }
            .onChange(of: shouldPulse) { _, newValue in
                isPulsing = newValue
            }
    }
}
