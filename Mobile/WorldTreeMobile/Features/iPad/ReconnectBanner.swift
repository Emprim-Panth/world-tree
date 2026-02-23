import SwiftUI

/// Amber banner displayed at the top of the detail column when reconnecting.
struct ReconnectBanner: View {
    @Environment(ConnectionManager.self) private var connectionManager

    private var reconnectAttempt: Int? {
        if case .reconnecting(let attempt) = connectionManager.state {
            return attempt
        }
        return nil
    }

    var isVisible: Bool {
        reconnectAttempt != nil
    }

    var body: some View {
        if let attempt = reconnectAttempt {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .medium))
                Text("Reconnecting (attempt \(attempt) of \(Constants.Network.reconnectMaxAttempts))…")
                    .font(DesignTokens.Typography.metaLabel)
            }
            .foregroundStyle(Color.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .background(Color.orange.opacity(0.15))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
