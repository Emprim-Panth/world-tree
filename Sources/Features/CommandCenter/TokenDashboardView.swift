import SwiftUI

// MARK: - Token Dashboard View

/// Collapsible section in Command Center showing token spend, burn rates, and context usage.
/// Polling-based (no GRDB observation) — refreshes on appear and every 30 seconds.
struct TokenDashboardView: View {
    @State private var isExpanded = false
    @State private var burnRates: [SessionBurnRate] = []
    @State private var dailyTotals: [DailyTokenTotal] = []
    @State private var projectSummaries: [ProjectTokenSummary] = []
    @State private var contextUsage: [SessionContextUsage] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            header

            if isExpanded {
                VStack(spacing: 12) {
                    if !burnRates.isEmpty {
                        burnRateSection
                    }
                    if !contextUsage.isEmpty {
                        contextWindowSection
                    }
                    if !dailyTotals.isEmpty {
                        dailyTrendSection
                    }
                    if burnRates.isEmpty && contextUsage.isEmpty && dailyTotals.isEmpty {
                        emptyState
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .onAppear {
            refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.3x3")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("TOKENS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                // Today / week totals
                if let today = todayTotal {
                    HStack(spacing: 8) {
                        tokenPill(label: "Today", count: today)
                        tokenPill(label: "7d", count: weekTotal)
                    }
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tokens section, \(isExpanded ? "expanded" : "collapsed")")
    }

    private func tokenPill(label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(formatTokens(count))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Burn Rates

    private var burnRateSection: some View {
        sectionCard(title: "Session Burn Rates") {
            let maxRate = burnRates.map(\.tokensPerMinute).max() ?? 1
            ForEach(burnRates.prefix(6)) { item in
                burnRateRow(item, maxRate: maxRate)
            }
        }
    }

    private func burnRateRow(_ item: SessionBurnRate, maxRate: Double) -> some View {
        let normalized = maxRate > 0 ? item.tokensPerMinute / maxRate : 0
        let barColor = burnRateColor(item.tokensPerMinute)
        return HStack(spacing: 8) {
            // Session label
            Text(item.project ?? item.sessionId.prefix(8).description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * normalized)
                }
            }
            .frame(height: 6)

            // Rate + total
            HStack(spacing: 4) {
                Text(String(format: "%.0f/min", item.tokensPerMinute))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(barColor)
                Text(formatTokens(item.totalTokens))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 90, alignment: .trailing)
        }
    }

    private func burnRateColor(_ rate: Double) -> Color {
        switch rate {
        case ...500:  return .green
        case ...3000: return .green
        case ...5000: return .orange
        default:      return .red
        }
    }

    // MARK: - Context Windows

    private var contextWindowSection: some View {
        sectionCard(title: "Context Windows") {
            ForEach(contextUsage.prefix(6)) { item in
                contextRow(item)
            }
        }
    }

    private func contextRow(_ item: SessionContextUsage) -> some View {
        let barColor = contextColor(item.percentUsed)
        return HStack(spacing: 8) {
            Text(item.project ?? item.sessionId.prefix(8).description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * min(item.percentUsed, 1.0))
                }
            }
            .frame(height: 6)

            HStack(spacing: 3) {
                Text(String(format: "%.0f%%", item.percentUsed * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(barColor)
                if item.percentUsed > 0.7 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(barColor)
                }
            }
            .frame(width: 50, alignment: .trailing)
        }
    }

    private func contextColor(_ pct: Double) -> Color {
        if pct > 0.9 { return .red }
        if pct > 0.7 { return .yellow }
        return .green
    }

    // MARK: - Daily Trend

    private var dailyTrendSection: some View {
        sectionCard(title: "Daily Trend (7d)") {
            trendChart
        }
    }

    private var trendChart: some View {
        // Aggregate per day (may have multiple model rows per day)
        let aggregated = aggregatedDailyTotals()
        let maxTotal = aggregated.map(\.total).max() ?? 1

        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(aggregated) { day in
                VStack(spacing: 2) {
                    // Bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.6))
                        .frame(height: max(4, CGFloat(day.total) / CGFloat(maxTotal) * 60))

                    // Day label
                    Text(dayLabel(day.date))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 80)
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "T" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return String(formatter.string(from: date).prefix(1))
    }

    private func aggregatedDailyTotals() -> [DailyTokenTotal] {
        var byDay: [String: (Date, Int, Int)] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for item in dailyTotals {
            let key = formatter.string(from: item.date)
            if let existing = byDay[key] {
                byDay[key] = (existing.0, existing.1 + item.inputTokens, existing.2 + item.outputTokens)
            } else {
                byDay[key] = (item.date, item.inputTokens, item.outputTokens)
            }
        }
        return byDay.values
            .sorted { $0.0 < $1.0 }
            .map { DailyTokenTotal(date: $0.0, inputTokens: $0.1, outputTokens: $0.2, model: nil) }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.bar")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No token data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Section Card

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            content()
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Computed Values

    private var todayTotal: Int? {
        let todayItems = dailyTotals.filter { Calendar.current.isDateInToday($0.date) }
        let total = todayItems.reduce(0) { $0 + $1.total }
        return total > 0 ? total : nil
    }

    private var weekTotal: Int {
        dailyTotals.reduce(0) { $0 + $1.total }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    // MARK: - Data Load

    @MainActor
    private func refresh() {
        let store = TokenStore.shared
        burnRates = store.burnRates()
        dailyTotals = store.dailyTotals()
        projectSummaries = store.projectSummaries()
        contextUsage = store.contextUsage()
    }
}
