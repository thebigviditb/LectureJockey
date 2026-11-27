import Foundation

/// A playback command LectureJockey can apply to a player.
public enum Command: Equatable, Sendable {
    /// Set the playback rate to an absolute value, e.g. 2.0.
    case setRate(Double)
    /// Change the playback rate by a step, e.g. +0.25 for "speed up".
    case changeRate(by: Double)
    /// Seek relative to the current position, in seconds (negative = back).
    case seek(by: Double)
    case pause
    case play

    public var summary: String {
        switch self {
        case .setRate(let r): return "rate \(Self.format(r))x"
        case .changeRate(let d): return "rate \(d > 0 ? "+" : "")\(Self.format(d))"
        case .seek(let s): return "seek \(s > 0 ? "+" : "")\(Self.format(s))s"
        case .pause: return "pause"
        case .play: return "play"
        }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
