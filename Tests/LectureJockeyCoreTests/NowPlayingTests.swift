import Foundation
import Testing
@testable import LectureJockeyCore

struct NowPlayingTests {
    /// Shape of `media-control get` for a SproutVideo lecture embedded in a page.
    func info(playing: Bool, elapsed: Double = 638.28, timestamp: String = "2026-11-27T21:15:31Z",
              bundle: String = "com.google.Chrome") -> Data {
        Data("""
            {"playbackRate": \(playing ? 1 : 0), "elapsedTime": \(elapsed), "timestamp": "\(timestamp)",
             "bundleIdentifier": "\(bundle)", "title": "A lecture", "duration": 2970.67, "playing": \(playing),
             "supportedCommands": [{"id": 0, "name": "Play"}, {"id": 24, "name": "SeekToPlaybackPosition"}]}
            """.utf8)
    }

    @Test func readsAPausedVideo() throws {
        let s = try #require(NowPlayingDriver.parse(info(playing: false), bundleID: ChromeDriver.bundleID)?.state)
        #expect(!s.playing)
        #expect(s.time == 638.28)
        #expect(s.duration == 2970.67)
    }

    @Test func advancesThePositionOfAPlayingVideoToNow() throws {
        let ts = ISO8601DateFormatter().date(from: "2026-11-27T21:15:31Z")!
        let s = try #require(NowPlayingDriver.parse(info(playing: true), bundleID: ChromeDriver.bundleID,
                                                    now: ts.addingTimeInterval(10))?.state)
        #expect(abs(s.time - 648.28) < 0.001)
    }

    @Test func ignoresMediaFromOtherApps() {
        // "pause" must never stop Spotify because Chrome had no reachable video.
        #expect(NowPlayingDriver.parse(info(playing: true, bundle: "com.spotify.client"), bundleID: ChromeDriver.bundleID) == nil)
        #expect(NowPlayingDriver.parse(Data("null".utf8), bundleID: ChromeDriver.bundleID) == nil)
    }

    @Test func cannotChangeSpeed() {
        let np = NowPlayingDriver(executable: "/nonexistent")
        #expect(!np.supports(.setRate(2)))
        #expect(!np.supports(.changeRate(by: 0.25)))
        #expect(np.supports(.seek(by: -15)))
        #expect(np.supports(.seekToFraction(0.5)))
        #expect(np.supports(.pause))
    }

    @Test func gateSkipsWhatTheDriverCannotDo() {
        let v = ChromeDriver.VideoState(playing: true, rate: 1, time: 600, duration: 2970, activeElement: "")
        #expect(Gate.check(.setRate(2), video: v, supported: false) == .skip("rate 2x is not possible for this embedded player"))
        #expect(Gate.check(.seek(by: -15), video: v, supported: true) == .run(.seek(by: -15)))
    }

    /// media-control rejects "0.0" and "0.5" ("'.5' is not a valid number") and "1e-05";
    /// a jump to the start of an embedded video used to fail on "0.0".
    @Test func seekArgumentsAreNumbersMediaControlAccepts() {
        #expect(NowPlayingDriver.seekArgument(0) == "0")
        #expect(NowPlayingDriver.seekArgument(0.65) == "0")
        #expect(NowPlayingDriver.seekArgument(0.00001) == "0")
        #expect(NowPlayingDriver.seekArgument(1) == "1.000")
        #expect(NowPlayingDriver.seekArgument(3.1074851535720827) == "3.107")
        #expect(NowPlayingDriver.seekArgument(665.4) == "665.400")
        #expect(NowPlayingDriver.seekArgument(.nan) == "0")
        #expect(NowPlayingDriver.seekArgument(.infinity) == "0")
    }

    @Test func routerLeavesOutAMissingTool() {
        #expect(PlayerRouter(nowPlaying: NowPlayingDriver(executable: "/nonexistent")).nowPlaying == nil)
    }
}
