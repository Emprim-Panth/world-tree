import Foundation

/// Shared date parsing with fallback strategies.
/// Replaces 5+ duplicated parsing implementations across the codebase.
enum DateParsing {
    private static let iso8601Full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let sqliteDatetime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Parse a date string trying multiple formats: ISO8601 (full), ISO8601 (basic), SQLite datetime, date-only.
    static func parse(_ string: String) -> Date? {
        iso8601Full.date(from: string)
            ?? iso8601Basic.date(from: string)
            ?? sqliteDatetime.date(from: string)
            ?? dateOnly.date(from: string)
    }

    /// Format a date as a relative string (e.g., "5m ago", "2h ago", "3d ago").
    static func relativeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
