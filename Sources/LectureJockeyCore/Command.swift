import Foundation

/// A playback command LectureJockey can apply to a player.
public enum Command: Equatable, Sendable {
    /// Set the playback rate to an absolute value, e.g. 2.0.
    case setRate(Double)
    /// Change the playback rate by a step, e.g. +0.25 for "speed up".
    case changeRate(by: Double)
    /// Seek relative to the current position, in seconds (negative = back).
    case seek(by: Double)
    /// Seek to an absolute position, in seconds from the start.
    case seekTo(Double)
    /// Seek to a fraction of the video's length, 0...1 (0.5 = the middle).
    case seekToFraction(Double)
    /// Return to where the last jump came from ("go back to where I was"). Resolved to a
    /// `seekTo` from `PositionHistory` before it reaches a driver.
    case returnToPrevious
    case pause
    case play

    public var summary: String {
        switch self {
        case .returnToPrevious: return "return to previous position"
        case .setRate(let r): return "rate \(Self.format(r))x"
        case .changeRate(let d): return "rate \(d > 0 ? "+" : "")\(Self.format(d))"
        case .seek(let s): return "seek \(s > 0 ? "+" : "")\(Self.format(s))s"
        case .seekTo(let s): return "seek to \(Self.format(s))s"
        case .seekToFraction(let f): return "seek to \(Self.format((f * 1000).rounded() / 10))%"
        case .pause: return "pause"
        case .play: return "play"
        }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
