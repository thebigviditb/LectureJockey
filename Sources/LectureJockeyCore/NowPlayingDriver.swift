import Foundation

/// A player LectureJockey can drive.
public protocol PlayerDriver: Sendable {
    var name: String { get }
    /// The video it would act on, or nil if it has none.
    func state() throws -> ChromeDriver.VideoState?
    func supports(_ command: Command) -> Bool
    @discardableResult func apply(_ command: Command) throws -> ChromeDriver.VideoState?
}

extension ChromeDriver: PlayerDriver {
    public var name: String { "chrome" }
    public func supports(_ command: Command) -> Bool { true }
}

/// Fallback for videos Chrome's JavaScript cannot reach, such as players embedded
/// from another domain (SproutVideo, Vimeo, Wistia): macOS Now Playing, which
/// Chrome feeds from any frame. Play, pause and seeking work; speed does not
/// (Chrome does not accept rate changes this way).
///
/// Uses the `media-control` CLI (`brew install media-control`). Apple restricted
/// the MediaRemote framework in macOS 15.4; the tool works through the system Perl,
/// which is entitled to it. That is a private framework, so a macOS update may break it.
public struct NowPlayingDriver: PlayerDriver {
    public var name: String { "now playing" }
    /// Only act on media Chrome is playing, never on Spotify or Music.
    public let bundleID: String
    public let executable: String

    public init(bundleID: String = ChromeDriver.bundleID, executable: String? = nil) {
        self.bundleID = bundleID
        self.executable = executable ?? Self.locate() ?? "/opt/homebrew/bin/media-control"
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    static func locate() -> String? {
        ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    public func supports(_ command: Command) -> Bool {
        switch command {
        case .setRate, .changeRate: return false
        case .seek, .seekTo, .seekToFraction, .pause, .play: return true
        }
    }

    public func state() throws -> ChromeDriver.VideoState? {
        guard let info = try nowPlaying() else { return nil }
        return info.state
    }

    @discardableResult
    public func apply(_ command: Command) throws -> ChromeDriver.VideoState? {
        guard let info = try nowPlaying() else { return nil }
        let s = info.state
        let end = s.duration > 0 ? s.duration - 0.5 : .infinity
        // Now Playing reports the new position only after a moment, so return what was
        // requested rather than re-reading a stale value.
        func seek(_ t: Double) throws -> ChromeDriver.VideoState {
            let target = max(0, min(end, t))
            try run(["seek", String(target)])
            return .init(playing: s.playing, rate: s.rate, time: target, duration: s.duration, activeElement: "")
        }
        switch command {
        case .seek(let by): return try seek(s.time + by)
        case .seekTo(let t): return try seek(t)
        case .seekToFraction(let f):
            guard s.duration > 0 else { return s }
            return try seek(s.duration * f)
        case .pause:
            try run(["pause"])
            return .init(playing: false, rate: s.rate, time: s.time, duration: s.duration, activeElement: "")
        case .play:
            try run(["play"])
            return .init(playing: true, rate: s.rate, time: s.time, duration: s.duration, activeElement: "")
        case .setRate, .changeRate: throw NowPlayingError.unsupported(command)
        }
    }

    // MARK: - media-control

    struct Info {
        let state: ChromeDriver.VideoState
    }

    /// Parses `media-control get`. Elapsed time is as of `timestamp`, so while playing
    /// the current position is elapsed + (now - timestamp) * rate.
    static func parse(_ data: Data, bundleID: String, now: Date = Date()) -> Info? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["bundleIdentifier"] as? String == bundleID else { return nil }
        let playing = obj["playing"] as? Bool ?? false
        let rate = obj["playbackRate"] as? Double ?? (playing ? 1 : 0)
        var elapsed = obj["elapsedTime"] as? Double ?? 0
        if playing, let ts = (obj["timestamp"] as? String).flatMap(ISO8601DateFormatter().date(from:)) {
            elapsed += max(0, now.timeIntervalSince(ts)) * (rate > 0 ? rate : 1)
        }
        let duration = obj["duration"] as? Double ?? 0
        if duration > 0 { elapsed = min(elapsed, duration) }
        return Info(state: .init(playing: playing, rate: rate > 0 ? rate : 1, time: elapsed,
                                 duration: duration, activeElement: ""))
    }

    private func nowPlaying() throws -> Info? {
        guard isInstalled else { return nil }
        return Self.parse(try run(["get"]), bundleID: bundleID)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NowPlayingError.failed(args.first ?? "", p.terminationStatus) }
        return data
    }
}

public enum NowPlayingError: Error, CustomStringConvertible {
    case unsupported(Command)
    case failed(String, Int32)

    public var description: String {
        switch self {
        case .unsupported(let c): return "\(c.summary) is not possible for this embedded player"
        case .failed(let cmd, let code): return "media-control \(cmd) exited with \(code)"
        }
    }
}

/// Picks the driver for the video you are watching: Chrome's JavaScript when it can
/// reach the video (everything works, including speed), else Now Playing. Decided
/// before acting, so a command never fails first and retries.
public struct PlayerRouter: Sendable {
    public let chrome: ChromeDriver
    public let nowPlaying: NowPlayingDriver?

    public init(chrome: ChromeDriver = ChromeDriver(), nowPlaying: NowPlayingDriver? = NowPlayingDriver()) {
        self.chrome = chrome
        self.nowPlaying = nowPlaying.flatMap { $0.isInstalled ? $0 : nil }
    }

    public func resolve() throws -> (driver: PlayerDriver, video: ChromeDriver.VideoState)? {
        if let v = try chrome.state() { return (chrome, v) }
        if let np = nowPlaying, let v = try np.state() { return (np, v) }
        return nil
    }
}
