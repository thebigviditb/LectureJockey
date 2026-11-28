import Foundation

/// Where you jumped from, so "go back to where I was" can return there, like a
/// browser's back button: every jump records the position it left, and returning
/// takes the most recent one off the list. One history per video.
public final class PositionHistory: @unchecked Sendable {
    public struct Point: Sendable, Equatable {
        public let time: Double
        public let at: Date
    }

    public static let limit = 20
    private let lock = NSLock()
    private var video = ""
    private var points: [Point] = []

    public init() {}

    /// Records the position a jump leaves. A different `video` starts a fresh history.
    public func recordJump(from time: Double, video: String, at date: Date = Date()) {
        lock.withLock {
            if video != self.video { self.video = video; points = [] }
            points.append(Point(time: time, at: date))
            if points.count > Self.limit { points.removeFirst(points.count - Self.limit) }
        }
    }

    /// The point a return would go to, without removing it.
    public func peek(video: String) -> Point? {
        lock.withLock { video == self.video ? points.last : nil }
    }

    /// Removes and returns the most recent point for `video`.
    public func popReturn(video: String) -> Point? {
        lock.withLock { video == self.video ? points.popLast() : nil }
    }

    /// Identifies a video well enough to keep histories apart: the player and its length.
    public static func videoID(driver: String, duration: Double) -> String {
        "\(driver)|\(Int(duration.rounded()))"
    }

    /// Commands that move the playhead record a return point.
    public static func isJump(_ c: Command) -> Bool {
        switch c {
        case .seek, .seekTo, .seekToFraction: return true
        case .setRate, .changeRate, .pause, .play, .returnToPrevious: return false
        }
    }
}
