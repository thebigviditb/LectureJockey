import Foundation
import Testing
@testable import LectureJockeyCore

/// Records duck/restore calls instead of touching Chrome.
final class FakeVolume: Ducker.Volume, @unchecked Sendable {
    private let lock = NSLock()
    private var _volume: Double
    private var _calls: [String] = []
    let playing: Bool

    init(volume: Double, playing: Bool = true) {
        _volume = volume
        self.playing = playing
    }

    var volume: Double { lock.withLock { _volume } }
    var calls: [String] { lock.withLock { _calls } }

    func duck(to level: Double) -> DuckToken? {
        lock.withLock {
            _calls.append("duck")
            guard playing, _volume > level else { return nil }
            let prev = _volume
            _volume = level
            return DuckToken(window: 1, tab: 2, previous: prev, level: level)
        }
    }

    func restore(_ token: DuckToken) {
        lock.withLock {
            _calls.append("restore")
            if abs(_volume - token.level) < 0.005 { _volume = token.previous }
        }
    }

    func userSets(_ v: Double) { lock.withLock { _volume = v } }
}

struct DuckerTests {
    func make(_ volume: FakeVolume, speakers: Bool = true, grace: TimeInterval = 0.15, cap: TimeInterval = 5) -> Ducker {
        var config = Ducker.Config()
        config.micStartGrace = grace
        config.maxDuration = cap
        return Ducker(volume: volume, speakersActive: { speakers }, config: config)
    }

    /// Lets queued work (and any due timers) run.
    func settle(_ d: Ducker, _ seconds: TimeInterval = 0.02) {
        Thread.sleep(forTimeInterval: seconds)
        _ = d.isDucked
    }

    @Test func ducksWhileRecordingAndRestoresWhenTheMicGoesIdle() {
        let v = FakeVolume(volume: 0.8)
        let d = make(v)
        d.recordingStarted("r1")
        d.micChanged(running: true)
        settle(d)
        #expect(v.volume == 0.10)
        d.micChanged(running: false)
        settle(d)
        #expect(v.volume == 0.8)
        #expect(!d.isDucked)
    }

    @Test func restoresWhenWisprFinishesTheRowFirst() {
        let v = FakeVolume(volume: 0.5)
        let d = make(v)
        d.micChanged(running: true)
        d.recordingStarted("r1")
        d.recordingFinished("other")
        settle(d)
        #expect(v.volume == 0.10, "another row finishing does not end this recording")
        d.recordingFinished("r1")
        settle(d)
        #expect(v.volume == 0.5)
    }

    @Test func restoresACancelledRecordingWhoseMicNeverStarted() {
        let v = FakeVolume(volume: 1.0)
        let d = make(v, grace: 0.1)
        d.recordingStarted("abandoned")
        settle(d)
        #expect(v.volume == 0.10)
        settle(d, 0.2)
        #expect(v.volume == 1.0)
    }

    @Test func safetyCapRestoresEvenIfTheMicStaysOn() {
        let v = FakeVolume(volume: 0.9)
        let d = make(v, cap: 0.15)
        d.micChanged(running: true)
        d.recordingStarted("r1")
        settle(d, 0.25)
        #expect(v.volume == 0.9)
    }

    @Test func leavesItAloneOnHeadphones() {
        let v = FakeVolume(volume: 0.8)
        let d = make(v, speakers: false)
        d.recordingStarted("r1")
        settle(d)
        #expect(v.calls.isEmpty)
        #expect(v.volume == 0.8)
    }

    @Test func doesNotRaiseAQuietVideo() {
        let v = FakeVolume(volume: 0.05)
        let d = make(v)
        d.recordingStarted("r1")
        settle(d)
        #expect(v.volume == 0.05)
        #expect(!d.isDucked)
    }

    @Test func keepsAVolumeTheUserChangedMidRecording() {
        let v = FakeVolume(volume: 0.8)
        let d = make(v)
        d.micChanged(running: true)
        d.recordingStarted("r1")
        settle(d)
        v.userSets(0.3)
        d.micChanged(running: false)
        settle(d)
        #expect(v.volume == 0.3)
    }

    @Test func restoreNowPutsItBackForExit() {
        let v = FakeVolume(volume: 0.7)
        let d = make(v)
        d.micChanged(running: true)
        d.recordingStarted("r1")
        settle(d)
        d.restoreNow()
        #expect(v.volume == 0.7)
    }
}
