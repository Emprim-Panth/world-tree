import Foundation

// MARK: - Session Health Model

/// Composite health score for an agent session.
/// Calculation is pure — no DB access. Takes AgentSession as input, returns SessionHealth.
struct SessionHealth {
    let sessionId: String
    let score: Double           // 0.0 (critical) to 1.0 (healthy)
    let level: HealthLevel
    let factors: [HealthFactor]

    enum HealthLevel: String, CaseIterable {
        case red, yellow, green

        var color: String {
            switch self {
            case .red:    return "red"
            case .yellow: return "yellow"
            case .green:  return "green"
            }
        }
    }

    struct HealthFactor {
        let name: String        // "error_rate", "burn_rate", "context", "productivity"
        let value: Double       // 0.0 to 1.0
        let description: String
    }
}

// MARK: - Calculator

extension SessionHealth {

    /// Calculate health score from a session snapshot.
    /// Always returns a result — never throws or returns nil.
    static func calculate(from session: AgentSession) -> SessionHealth {

        // MARK: Static overrides (always red regardless of other factors)
        if session.status == .stuck {
            return Self.alwaysRed(sessionId: session.id, reason: "Session is stuck")
        }
        if session.consecutiveErrors >= 5 {
            return Self.alwaysRed(sessionId: session.id, reason: "\(session.consecutiveErrors) consecutive errors")
        }
        let contextRatio = session.contextMax > 0
            ? Double(session.contextUsed) / Double(session.contextMax)
            : 0.0
        if contextRatio > 0.95 {
            return Self.alwaysRed(sessionId: session.id, reason: "Context window \(Int(contextRatio * 100))% full")
        }

        // MARK: Factor 1 — Error Rate (weight: 0.35)
        let errorScore = 1.0 - min(Double(session.consecutiveErrors) / 5.0, 1.0)
        let errorFactor = HealthFactor(
            name: "error_rate",
            value: errorScore,
            description: session.consecutiveErrors == 0
                ? "No consecutive errors"
                : "\(session.consecutiveErrors) consecutive error(s)"
        )

        // MARK: Factor 2 — Burn Rate (weight: 0.25)
        let burnScore: Double
        let burnDescription: String
        let elapsed = session.elapsedMinutes
        if elapsed < 1.0 || session.tokensOut < 10 {
            // Too new to judge — assume healthy
            burnScore = 1.0
            burnDescription = "Session just started"
        } else {
            let rate = Double(session.tokensOut) / elapsed
            switch rate {
            case ...100:
                // Very low — may be stuck (unless < 5 minutes old)
                burnScore = elapsed > 5 ? 0.3 : 0.8
                burnDescription = String(format: "%.0f tok/min (low)", rate)
            case 100...500:
                burnScore = 0.7
                burnDescription = String(format: "%.0f tok/min", rate)
            case 500...3000:
                burnScore = 1.0
                burnDescription = String(format: "%.0f tok/min (healthy)", rate)
            case 3000...5000:
                burnScore = 0.85
                burnDescription = String(format: "%.0f tok/min (elevated)", rate)
            default:
                // >5000 — may be in a loop
                burnScore = 0.7
                burnDescription = String(format: "%.0f tok/min (high)", rate)
            }
        }
        let burnFactor = HealthFactor(name: "burn_rate", value: burnScore, description: burnDescription)

        // MARK: Factor 3 — Context Pressure (weight: 0.25)
        let contextScore: Double
        let contextDescription: String
        switch contextRatio {
        case ...0.70:
            contextScore = 1.0
            contextDescription = String(format: "%.0f%% used", contextRatio * 100)
        case 0.70...0.90:
            contextScore = 0.5
            contextDescription = String(format: "%.0f%% used (warning)", contextRatio * 100)
        default:
            contextScore = 0.1
            contextDescription = String(format: "%.0f%% used (critical)", contextRatio * 100)
        }
        let contextFactor = HealthFactor(name: "context", value: contextScore, description: contextDescription)

        // MARK: Factor 4 — File Diversity / Productivity (weight: 0.15)
        let uniqueFiles = session.filesChangedArray.count
        let fileScore: Double
        let fileDescription: String
        if uniqueFiles == 0 && elapsed > 10 {
            fileScore = 0.2
            fileDescription = "No files touched after \(Int(elapsed))m"
        } else {
            fileScore = min(Double(uniqueFiles) / 3.0, 1.0)
            fileDescription = uniqueFiles == 0
                ? "No files yet"
                : "\(uniqueFiles) file(s) touched"
        }
        let fileFactor = HealthFactor(name: "productivity", value: fileScore, description: fileDescription)

        // MARK: Composite
        let composite = (errorScore * 0.35)
                      + (burnScore * 0.25)
                      + (contextScore * 0.25)
                      + (fileScore * 0.15)

        let level: HealthLevel
        switch composite {
        case 0.65...: level = .green
        case 0.35...: level = .yellow
        default:      level = .red
        }

        return SessionHealth(
            sessionId: session.id,
            score: composite,
            level: level,
            factors: [errorFactor, burnFactor, contextFactor, fileFactor]
        )
    }

    // MARK: - Private

    private static func alwaysRed(sessionId: String, reason: String) -> SessionHealth {
        SessionHealth(
            sessionId: sessionId,
            score: 0.0,
            level: .red,
            factors: [HealthFactor(name: "override", value: 0.0, description: reason)]
        )
    }
}

// MARK: - AgentSession Helpers

private extension AgentSession {
    /// Minutes the session has been running. Returns 0 if start time unknown.
    var elapsedMinutes: Double {
        guard let start = startedAt else { return 0 }
        return max(Date().timeIntervalSince(start) / 60.0, 0)
    }

    /// Context window usage as a fraction (0–1).
    var contextRatio: Double {
        guard contextMax > 0 else { return 0 }
        return Double(contextUsed) / Double(contextMax)
    }
}
