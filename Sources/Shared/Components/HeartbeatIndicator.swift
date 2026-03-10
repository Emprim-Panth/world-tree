import SwiftUI

// MARK: - Heartbeat Status

enum HeartbeatStatus {
    case active   // dispatches running
    case healthy  // recent heartbeat, no dispatches
    case idle     // no recent heartbeat
    case error    // system issue

    var color: Color {
        switch self {
        case .active: .cyan
        case .healthy: .blue
        case .idle: .blue.opacity(0.5)
        case .error: .red
        }
    }

    var pulseSpeed: Double {
        switch self {
        case .active: 0.6
        case .healthy: 1.2
        case .idle: 2.0
        case .error: 0  // no pulse
        }
    }

    var shouldPulse: Bool {
        self != .error
    }
}

// MARK: - Heartbeat Indicator

struct HeartbeatIndicator: View {
    let activeTaskCount: Int
    let lastHeartbeat: Date?
    let signalCount: Int

    @State private var isPulsing = false

    private var status: HeartbeatStatus {
        // Error if no heartbeat in over an hour
        if let last = lastHeartbeat, Date().timeIntervalSince(last) > 3600 {
            return .error
        }
        if activeTaskCount > 0 { return .active }
        if let last = lastHeartbeat, Date().timeIntervalSince(last) < 1800 {
            return .healthy
        }
        return .idle
    }

    private var statusText: String {
        switch status {
        case .active:
            return activeTaskCount == 1
                ? "Cortana \u{2022} 1 task"
                : "Cortana \u{2022} \(activeTaskCount) tasks"
        case .healthy:
            if signalCount > 0 {
                return "Cortana \u{2022} \(signalCount) signals"
            }
            return "Cortana \u{2022} Active"
        case .idle:
            return "Cortana \u{2022} Idle"
        case .error:
            return "Cortana \u{2022} Offline"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Pulse dot
            ZStack {
                // Outer expanding ring
                if status.shouldPulse {
                    Circle()
                        .fill(status.color.opacity(0.3))
                        .frame(width: 14, height: 14)
                        .scaleEffect(isPulsing ? 1.8 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.4)
                }

                // Inner solid dot
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPulsing && status.shouldPulse ? 1.15 : 1.0)
            }
            .frame(width: 16, height: 16)

            // Status text
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(status.color)
        }
        .onAppear { startPulse() }
        .onChange(of: activeTaskCount) { _, _ in startPulse() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private func startPulse() {
        guard status.shouldPulse else {
            isPulsing = false
            return
        }
        // Reset then animate
        isPulsing = false
        withAnimation(
            .easeInOut(duration: status.pulseSpeed)
            .repeatForever(autoreverses: true)
        ) {
            isPulsing = true
        }
    }
}
