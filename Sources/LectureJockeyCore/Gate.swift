import Foundation

/// Decides whether a dictation is a playback command. A dictation counts only
/// when all of these hold:
///   1. Wispr typed it into a supported player app,
///   2. it is fresh: finished speaking at most `maxAge` ago (not an old row seen late),
///   3. the whole utterance matches a grammar rule, or (when none does) Jev
///      classifies it as a command with high confidence,
///   4. that app's front tab has a video (playing or paused: rewinding a paused
///      lecture is normal).
public enum Gate {
    public static let maxAge: TimeInterval = 15
    public static let supportedApps: Set<String> = [ChromeDriver.bundleID]

    public enum Decision: Equatable, Sendable {
        case run(Command)
        /// No grammar rule matched, but the context fits: ask the classifier.
        case ask
        case skip(String)
    }

    /// Checks 1-3, which need no call into the player or the network.
    public static func precheck(_ d: Dictation, now: Date = Date()) -> Decision {
        let command = CommandParser.parse(d.text)
        guard supportedApps.contains(d.app) else {
            return .skip(command == nil
                ? "not a command"
                : "target app \(d.app.isEmpty ? "unknown" : d.app) is not a supported player")
        }
        guard let end = d.endDate, now.timeIntervalSince(end) <= maxAge else { return .skip("stale dictation") }
        return command.map(Decision.run) ?? .ask
    }

    /// Check 4, given what the player reports.
    public static func check(_ command: Command, video: ChromeDriver.VideoState?, supported: Bool = true) -> Decision {
        guard let video else { return .skip("no video in the front tab") }
        guard supported else { return .skip("\(command.summary) is not possible for this embedded player") }
        if command == .play, video.playing { return .skip("already playing") }
        if command == .pause, !video.playing { return .skip("already paused") }
        return .run(command)
    }
}
