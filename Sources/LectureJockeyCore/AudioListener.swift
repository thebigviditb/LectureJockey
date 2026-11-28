import CoreAudio
import Foundation
import os

/// Listens to one app's audio with a Core Audio process tap, without changing what
/// you hear (the tap is unmuted). Used for live transcription: it hears the app's own
/// output at full level, not the room or the microphone, and not the volume dip.
///
/// Samples arrive on the real-time audio thread and are copied into a preallocated
/// ring, so nothing is allocated or locked for long there; `drain()` reads them on
/// any other thread.
public final class AudioListener: @unchecked Sendable {
    public let bundlePrefix: String
    public private(set) var sampleRate: Double = 48000
    public private(set) var channels = 2

    private var tap = AudioObjectID(0)
    private var aggregate = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private let ring: SampleRing

    public init(bundlePrefix: String, seconds: Double = 20) {
        self.bundlePrefix = bundlePrefix
        ring = SampleRing(capacity: Int(48000 * 2 * seconds))
    }

    public var isRunning: Bool { ioProc != nil }

    /// Wall-clock time of the first sample delivered, once audio is flowing.
    public var startDate: Date? { ring.startDate }

    public func start() throws {
        guard !isRunning else { return }
        let processes = ChromeAudioTap.processObjects(bundlePrefix: bundlePrefix)
        guard !processes.isEmpty else { throw TapError.noProcess }
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "LectureJockey listen"
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create listen tap")

        // The tap's own format: the stereo mixdown is interleaved Float32.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioDevices.address(kAudioTapPropertyFormat)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
            channels = max(1, Int(asbd.mChannelsPerFrame))
        }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LectureJockey listen",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "create listen device")
            ring.reset()
            let ring = self.ring
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, inputTime, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, let data = first.mData else { return }
                ring.write(data.assumingMemoryBound(to: Float.self), count: Int(first.mDataByteSize) / 4,
                           hostTime: inputTime.pointee.mHostTime)
            }, "create listen IO proc")
            try check(AudioDeviceStart(aggregate, ioProc), "start listening")
        } catch {
            stop()
            throw error
        }
    }

    /// Interleaved samples captured since the last call.
    public func drain() -> [Float] { ring.read() }

    /// Samples lost because nobody drained in time.
    public var droppedSamples: Int { ring.dropped }

    public func stop() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = 0
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        tap = 0
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.coreAudio(what, status) }
    }
}

/// A fixed-size sample ring: one writer on the audio thread, one reader elsewhere.
final class SampleRing: @unchecked Sendable {
    private struct State {
        var samples: [Float]
        var write = 0
        var count = 0
        var dropped = 0
        var firstHostTime: UInt64 = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        state = OSAllocatedUnfairLock(initialState: State(samples: [Float](repeating: 0, count: capacity)))
    }

    func reset() {
        state.withLock { $0.write = 0; $0.count = 0; $0.dropped = 0; $0.firstHostTime = 0 }
    }

    /// Called on the real-time thread: copies into the preallocated array, no allocation.
    func write(_ src: UnsafePointer<Float>, count n: Int, hostTime: UInt64) {
        state.withLockUnchecked { s in
            if s.firstHostTime == 0 { s.firstHostTime = hostTime }
            let cap = capacity
            s.samples.withUnsafeMutableBufferPointer { buf in
                for i in 0..<n { buf[(s.write + i) % cap] = src[i] }
            }
            s.write = (s.write + n) % cap
            let overflow = max(0, s.count + n - cap)
            s.dropped += overflow
            s.count = min(cap, s.count + n)
        }
    }

    func read() -> [Float] {
        state.withLock { s in
            guard s.count > 0 else { return [] }
            let cap = capacity
            let start = (s.write - s.count + cap) % cap
            var out = [Float](repeating: 0, count: s.count)
            for i in 0..<s.count { out[i] = s.samples[(start + i) % cap] }
            s.count = 0
            return out
        }
    }

    var dropped: Int { state.withLock { $0.dropped } }

    /// The first sample's host time as a wall-clock date.
    var startDate: Date? {
        let host = state.withLock { $0.firstHostTime }
        guard host != 0 else { return nil }
        return Self.date(forHostTime: host)
    }

    static func date(forHostTime host: UInt64) -> Date {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let toSeconds = { (t: UInt64) in Double(t) * Double(info.numer) / Double(info.denom) / 1e9 }
        let now = mach_absolute_time()
        return Date().addingTimeInterval(toSeconds(host) - toSeconds(now))
    }
}
