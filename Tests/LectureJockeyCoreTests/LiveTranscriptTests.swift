import Foundation
import Testing
@testable import LectureJockeyCore

struct PlaybackClockTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func advancesWhilePlayingAtTheReportedRate() {
        var c = PlaybackClock()
        c.add(.init(wall: t0, elapsed: 600, rate: 1, playing: true))
        #expect(c.videoTime(at: t0.addingTimeInterval(10)) == 610)
        c.add(.init(wall: t0.addingTimeInterval(20), elapsed: 620, rate: 2, playing: true))
        #expect(c.videoTime(at: t0.addingTimeInterval(25)) == 630, "at 2x, 5 s of listening is 10 s of video")
    }

    @Test func followsSeeksAndPauses() {
        var c = PlaybackClock()
        c.add(.init(wall: t0, elapsed: 600, rate: 1, playing: true))
        c.add(.init(wall: t0.addingTimeInterval(30), elapsed: 120, rate: 1, playing: true))   // rewound to 2:00
        c.add(.init(wall: t0.addingTimeInterval(60), elapsed: 150, rate: 1, playing: false))  // paused
        #expect(c.videoTime(at: t0.addingTimeInterval(15)) == 615)
        #expect(c.videoTime(at: t0.addingTimeInterval(40)) == 130)
        #expect(c.videoTime(at: t0.addingTimeInterval(70)) == nil, "nothing to transcribe while paused")
    }

    @Test func readsNowPlayingState() {
        var c = PlaybackClock()
        c.add(nowPlaying: ["elapsedTime": 638.28, "timestamp": "2026-11-27T21:15:31Z", "playing": true, "playbackRate": 1])
        let ts = ISO8601DateFormatter().date(from: "2026-11-27T21:15:31Z")!
        #expect(c.videoTime(at: ts.addingTimeInterval(2)).map { ($0 * 100).rounded() / 100 } == 640.28)
    }
}

struct LiveMergeTests {
    func empty() -> Transcript {
        Transcript(key: "nowplaying:x|2971", title: "x", duration: 2971, source: .live, segments: [], covered: [])
    }

    @Test func rewatchingReplacesInsteadOfDuplicating() {
        var t = empty()
        t.merge(live: .init(start: 600, end: 606, text: "the sequence matters"))
        t.merge(live: .init(start: 606, end: 611, text: "because of the opener"))
        // Rewound and heard the first line again, timed a little differently.
        t.merge(live: .init(start: 600.6, end: 606.4, text: "the sequence matters a lot"))
        #expect(t.segments.map(\.text) == ["the sequence matters a lot", "because of the opener"])
    }

    @Test func coverageMergesNearbyStretchesAndKeepsGaps() {
        var t = empty()
        t.merge(live: .init(start: 600, end: 606, text: "a"))
        t.merge(live: .init(start: 607.5, end: 612, text: "b"))
        t.merge(live: .init(start: 900, end: 905, text: "c"))   // skipped ahead
        #expect(t.covered == [[600, 612], [900, 905]])
    }

    @Test func ignoresEmptyOrBackwardsSegments() {
        var t = empty()
        t.merge(live: .init(start: 10, end: 10, text: "x"))
        t.merge(live: .init(start: 10, end: 12, text: ""))
        #expect(t.segments.isEmpty)
    }

    @Test func liveKeysNameTheVideoAndItsLength() {
        #expect(Transcript.liveKey(title: "Why the Sequence Matters", duration: 2970.67) == "nowplaying:Why the Sequence Matters|2971")
    }
}
