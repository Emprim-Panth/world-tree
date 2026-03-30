import Foundation
import os.log

// MARK: - Logging

private let appLogger = Logger(subsystem: "com.forgeandcode.WorldTree", category: "App")

/// Lightweight app-level logger. Use instead of print() so logs appear in Console.app.
func wtLog(_ message: String) {
    appLogger.info("\(message, privacy: .public)")
}

// MARK: - JSON Helpers

/// Escape a string for safe embedding in a JSON string literal.
/// JSONSerialization only accepts arrays/dictionaries at the top level and will
/// throw an Objective-C exception for bare strings, so escape manually here.
func escapeJSONString(_ s: String) -> String {
    var escaped = String()
    escaped.reserveCapacity(s.count)

    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"":
            escaped += "\\\""
        case "\\":
            escaped += "\\\\"
        case "\u{08}":
            escaped += "\\b"
        case "\u{0C}":
            escaped += "\\f"
        case "\n":
            escaped += "\\n"
        case "\r":
            escaped += "\\r"
        case "\t":
            escaped += "\\t"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                escaped += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
    }

    return escaped
}
