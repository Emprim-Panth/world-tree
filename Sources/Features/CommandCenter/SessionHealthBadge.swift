import SwiftUI

// MARK: - Session Health Badge

/// Compact health indicator: colored circle with popover showing factor breakdown.
/// Red/yellow/green maps to SessionHealth.HealthLevel.
struct SessionHealthBadge: View {
    let health: SessionHealth?
    var size: CGFloat = 8

    @State private var isShowingPopover = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: size, height: size)
            .shadow(color: dotColor.opacity(0.5), radius: 2)
            .onHover { hovering in
                if health != nil {
                    isShowingPopover = hovering
                }
            }
            .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
                if let health {
                    HealthDetailPopover(health: health)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private var dotColor: Color {
        guard let health else { return .gray.opacity(0.4) }
        switch health.level {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        }
    }

    private var accessibilityLabel: String {
        guard let health else { return "Health unknown" }
        return "Health: \(health.level.rawValue), score \(String(format: "%.2f", health.score))"
    }
}

// MARK: - Detail Popover

private struct HealthDetailPopover: View {
    let health: SessionHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(levelColor)
                    .frame(width: 8, height: 8)
                Text("Health: \(String(format: "%.2f", health.score)) (\(health.level.rawValue.capitalized))")
                    .font(.system(size: 12, weight: .semibold))
            }

            Divider()

            // Factors
            ForEach(health.factors, id: \.name) { factor in
                FactorRow(factor: factor)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private var levelColor: Color {
        switch health.level {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        }
    }
}

private struct FactorRow: View {
    let factor: SessionHealth.HealthFactor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", factor.value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(barColor)
            }

            // Mini progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor)
                        .frame(width: geo.size.width * factor.value)
                }
            }
            .frame(height: 3)

            Text(factor.description)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var displayName: String {
        switch factor.name {
        case "error_rate":   return "Errors"
        case "burn_rate":    return "Burn Rate"
        case "context":      return "Context"
        case "productivity": return "Files"
        case "override":     return "Override"
        default:             return factor.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var barColor: Color {
        switch factor.value {
        case 0.65...: return .green
        case 0.35...: return .yellow
        default:      return .red
        }
    }
}
