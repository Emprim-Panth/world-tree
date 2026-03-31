import SwiftUI

/// Semantic color tokens for World Tree.
/// All view-layer colors should reference Palette instead of bare SwiftUI colors.
/// This enables consistent theming and makes future design system changes trivial.
enum Palette {

    // MARK: - Status

    static let success = Color.green
    static let error = Color.red
    static let warning = Color.orange
    static let info = Color.blue
    static let neutral = Color.gray

    // MARK: - Priority

    static let critical = Color.red
    static let high = Color.orange
    static let medium = Color.yellow
    static let low = Color.gray

    // MARK: - Ticket Status

    static let done = Color.green
    static let inProgress = Color.blue
    static let blocked = Color.red
    static let review = Color.purple
    static let pending = Color.gray
    static let cancelled = Color.gray

    // MARK: - Phase

    static let exploring = Color.cyan
    static let implementing = Color.blue
    static let testing = Color.green
    static let debugging = Color.orange
    static let shipping = Color.purple
    static let idle = Color.gray

    // MARK: - Agent / Crew

    static let active = Color.green
    static let dispatched = Color.cyan
    static let completed = Color.green
    static let failed = Color.red

    // MARK: - Intelligence

    static let local = Color.green
    static let escalated = Color.orange
    static let claude = Color.purple

    // MARK: - Surfaces

    static let cardBackground = Color(NSColor.controlBackgroundColor)
    static let windowBackground = Color(NSColor.windowBackgroundColor)
    static let terminalBackground = Color.black
    static let codeBackground = Color(NSColor.textBackgroundColor)

    // MARK: - Accents

    static let accent = Color.cyan
    static let cortana = Color.cyan
    static let link = Color.blue
    static let destructive = Color.red

    // MARK: - Indicators

    static let dirty = Color.orange
    static let clean = Color.green
    static let stale = Color.red

    // MARK: - Resolvers

    /// Map a TicketStatus enum to its color.
    static func forStatus(_ status: TicketStatus) -> Color {
        switch status {
        case .done: return done
        case .inProgress: return inProgress
        case .blocked: return blocked
        case .review: return review
        case .cancelled: return cancelled
        case .pending: return pending
        case .unknown: return neutral
        }
    }

    /// Map a status string to its color (for non-ticket contexts like alerts, agent sessions).
    static func forStatus(_ status: String) -> Color {
        switch status {
        case "done": return done
        case "in_progress": return inProgress
        case "blocked": return blocked
        case "review": return review
        case "cancelled": return cancelled
        case "running": return inProgress
        case "queued": return pending
        case "failed": return failed
        case "completed": return completed
        default: return neutral
        }
    }

    /// Map a priority string to its color.
    static func forPriority(_ priority: String) -> Color {
        switch priority {
        case "critical": return critical
        case "high": return high
        case "medium": return medium
        case "low": return low
        default: return neutral
        }
    }

    /// Map a compass phase string to its color.
    static func forPhase(_ phase: String) -> Color {
        switch phase {
        case "exploring": return exploring
        case "implementing": return implementing
        case "testing": return testing
        case "debugging": return debugging
        case "shipping": return shipping
        default: return idle
        }
    }
}
