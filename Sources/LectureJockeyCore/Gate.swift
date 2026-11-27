import Foundation

/// Decides whether a dictation is a playback command. A dictation counts only
/// when all of these hold:
///   1. the whole utterance parses as a command,
///   2. Wispr typed it into a supported player app,
///   3. it is fresh: finished speaking at most `maxAge` ago (not an old row seen late),
///   4. that app has a video, playing (or paused, for "play").
public enum Gate {
    public static let maxAge: TimeInterval = 15
    public static let supportedApps: Set<String> = [ChromeDriver.bundleID]

    public enum Decision: Equatable, Sendable {
        case run(Command)
        case skip(String)
    }

    /// Checks 1-3, which need no call into the player.
    public static func precheck(_ d: Dictation, now: Date = Date()) -> Decision {
        guard let command = CommandParser.parse(d.text) else { return .skip("not a command") }
        guard supportedApps.contains(d.app) else {
            return .skip("target app \(d.app.isEmpty ? "unknown" : d.app) is not a supported player")
        }
        guard let end = d.endDate, now.timeIntervalSince(end) <= maxAge else { return .skip("stale dictation") }
        return .run(command)
    }

    /// Check 4, given what the player reports.
    public static func check(_ command: Command, video: ChromeDriver.VideoState?) -> Decision {
        guard let video else { return .skip("no video in the front tab") }
        if command == .play { return video.playing ? .skip("already playing") : .run(command) }
        return video.playing ? .run(command) : .skip("video is not playing")
    }
}
