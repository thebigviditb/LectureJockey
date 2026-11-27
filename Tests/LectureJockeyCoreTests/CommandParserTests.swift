import Foundation
import Testing
@testable import LectureJockeyCore

struct CommandParserTests {
    @Test(arguments: [
        ("Speed up 2x.", Command.setRate(2)),
        ("2x", .setRate(2)),
        ("2X", .setRate(2)),
        ("two x", .setRate(2)),
        ("Set the speed to 1.5x", .setRate(1.5)),
        ("set the speed to 1.5", .setRate(1.5)),
        ("Play at 1.25x.", .setRate(1.25)),
        ("Two times speed", .setRate(2)),
        ("one and a half x", .setRate(1.5)),
        ("Speed it up to 3x", .setRate(3)),
        ("Normal speed.", .setRate(1)),
        ("Go back to normal speed", .setRate(1)),
        ("Speed up", .changeRate(by: 0.25)),
        ("Faster", .changeRate(by: 0.25)),
        ("Slow down.", .changeRate(by: -0.25)),
        ("Go back 30 seconds.", .seek(by: -30)),
        ("Go back thirty seconds", .seek(by: -30)),
        ("Rewind 10 seconds", .seek(by: -10)),
        ("Back 45 seconds", .seek(by: -45)),
        ("Go back a minute.", .seek(by: -60)),
        ("Go back half a minute", .seek(by: -30)),
        ("Skip ahead 2 minutes", .seek(by: 120)),
        ("Skip forward thirty five seconds", .seek(by: 35)),
        ("Fast forward 1 minute", .seek(by: 60)),
        ("Jump ahead by 90 seconds", .seek(by: 90)),
        ("Pause.", .pause),
        ("Pause the video", .pause),
        ("Play", .play),
        ("Resume.", .play),
        ("Can you go back 30 seconds, please?", .seek(by: -30)),
        ("Go to the beginning of the video.", .seekTo(0)),
        ("Go back to the start", .seekTo(0)),
        ("Restart the video", .seekTo(0)),
        ("Start over.", .seekTo(0)),
        ("Go to 5 minutes", .seekTo(300)),
        ("Jump to minute 12", .seekTo(720)),
        ("Skip to 1 minute 30 seconds", .seekTo(90)),
        ("Go to 2 minutes and 15 seconds.", .seekTo(135)),
        ("Jump to 2:30", .seekTo(150)),
        ("Go to 1:02:30", .seekTo(3750)),
        ("Go to ninety seconds", .seekTo(90)),
        ("Go to the middle of the video.", .seekToFraction(0.5)),
        ("Jump to the middle", .seekToFraction(0.5)),
        ("Skip to the halfway point", .seekToFraction(0.5)),
        ("Go halfway through the video", .seekToFraction(0.5)),
        ("Go to the end of the video", .seekToFraction(1)),
        ("Jump to 75 percent", .seekToFraction(0.75)),
        ("Go to 80% of the way through", .seekToFraction(0.8)),
        ("Skip to a quarter of the way through", .seekToFraction(0.25)),
        ("Jump to three quarters of the way in", .seekToFraction(0.75)),
        ("Go to a third of the way through the lecture", .seekToFraction(1.0 / 3)),
    ])
    func parses(_ text: String, _ expected: Command) {
        #expect(CommandParser.parse(text) == expected)
    }

    /// Ordinary dictation that merely contains a command phrase must not trigger.
    @Test(arguments: [
        "I need to go back 30 seconds in my notes and check what he said about the FTC case",
        "We should speed up the release, maybe 2x faster than last quarter.",
        "Pause for a second and think about it.",
        "Let's play it by ear.",
        "go back",
        "speed",
        "Set the speed to 10x",
        "Go back 0 seconds",
        "Rewind 30",
        "",
        "Thanks, that looks good.",
        "Go to the beginning of the document and fix the title",
        "Jump to 2:75",
        "Go to the middle of the street",
        "Jump to 150 percent",
        "We need to get to the end of this project",
    ])
    func rejects(_ text: String) {
        #expect(CommandParser.parse(text) == nil)
    }
}

struct GateTests {
    let now = WisprHistory.parseTimestamp("2026-11-27 18:40:21.915 +00:00")!

    func dictation(_ text: String, app: String = ChromeDriver.bundleID, at ts: String = "2026-11-27 18:40:20.000 +00:00", duration: Double = 1.5) -> Dictation {
        Dictation(id: "x", timestamp: ts, app: app, url: "youtube.com", text: text, status: "formatted", duration: duration)
    }

    let playing = ChromeDriver.VideoState(playing: true, rate: 1, time: 100, duration: 600, activeElement: "body")
    let paused = ChromeDriver.VideoState(playing: false, rate: 1, time: 100, duration: 600, activeElement: "body")

    @Test func runsCommandForChrome() {
        #expect(Gate.precheck(dictation("2x"), now: now) == .run(.setRate(2)))
    }

    @Test func skipsOtherApps() {
        // "go back 30 seconds" dictated into VS Code while a lecture plays must not seek it.
        #expect(Gate.precheck(dictation("go back 30 seconds", app: "com.microsoft.VSCode"), now: now)
                == .skip("target app com.microsoft.VSCode is not a supported player"))
    }

    @Test func skipsStaleRows() {
        #expect(Gate.precheck(dictation("2x", at: "2026-11-27 18:30:00.000 +00:00"), now: now) == .skip("stale dictation"))
    }

    @Test func ageCountsFromWhenYouStoppedSpeaking() {
        // Started 20 s ago but spoke for 10 s: finished 10 s ago, still fresh.
        #expect(Gate.precheck(dictation("2x", at: "2026-11-27 18:40:01.915 +00:00", duration: 10), now: now) == .run(.setRate(2)))
    }

    @Test func needsAVideo() {
        #expect(Gate.check(.setRate(2), video: playing) == .run(.setRate(2)))
        #expect(Gate.check(.setRate(2), video: nil) == .skip("no video in the front tab"))
    }

    @Test func pausedVideoTakesSeeksAndRate() {
        #expect(Gate.check(.seekTo(0), video: paused) == .run(.seekTo(0)))
        #expect(Gate.check(.seek(by: -30), video: paused) == .run(.seek(by: -30)))
        #expect(Gate.check(.setRate(2), video: paused) == .run(.setRate(2)))
        #expect(Gate.check(.pause, video: paused) == .skip("already paused"))
    }

    @Test func playWorksOnPausedVideo() {
        #expect(Gate.check(.play, video: paused) == .run(.play))
        #expect(Gate.check(.play, video: playing) == .skip("already playing"))
    }

    @Test func parsesWisprTimestamps() {
        #expect(now.timeIntervalSince1970 == 1795804821.915)
    }
}
