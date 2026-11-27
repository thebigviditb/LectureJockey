import CoreAudio
import Foundation

/// Lowers all of Chrome's audio by tapping it with a Core Audio process tap
/// (macOS 14.2+): the tap mutes Chrome's own output and this plays the tapped
/// audio back at `gain` through a private aggregate device on the current output.
///
/// Used only for videos Chrome's JavaScript cannot reach (players embedded from
/// another domain), where the per-video volume is out of reach. Chrome plays from
/// helper processes, so every process whose bundle ID starts with Chrome's is tapped.
///
/// Capturing another app's audio needs the System Audio Recording permission; the
/// app that launched LectureJockey (Terminal, VS Code) is the one macOS asks about.
/// A packaged app will need NSAudioCaptureUsageDescription in its Info.plist.
public final class ChromeAudioTap: @unchecked Sendable {
    public let bundlePrefix: String
    private var tap = AudioObjectID(0)
    private var aggregate = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private let gainBox = GainBox()

    public init(bundlePrefix: String = ChromeDriver.bundleID) {
        self.bundlePrefix = bundlePrefix
    }

    public var isActive: Bool { ioProc != nil }

    /// Starts playing Chrome at `gain` (0...1). Not thread-safe; call from one queue.
    public func start(gain: Double) throws {
        guard !isActive else { return }
        let processes = Self.processObjects(bundlePrefix: bundlePrefix)
        guard !processes.isEmpty else { throw TapError.noProcess }
        guard let output = Self.defaultOutputUID() else { throw TapError.noOutput }

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "LectureJockey"
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create tap")

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LectureJockey",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "create aggregate device")
            gainBox.value = Float(max(0, min(1, gain)))
            let box = gainBox
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
                Self.copy(input, to: output, gain: box.value)
            }, "create IO proc")
            try check(AudioDeviceStart(aggregate, ioProc), "start")
        } catch {
            stop()
            throw error
        }
    }

    /// Restores Chrome's normal output. Safe to call when not active.
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

    // MARK: - Audio

    /// Copies tapped frames to the output scaled by `gain`, mapping channels when the
    /// tap (stereo) and the output differ. Works on interleaved Float32 buffers.
    static func copy(_ input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for (i, out) in outs.enumerated() {
            guard let od = out.mData else { continue }
            let outCh = max(1, Int(out.mNumberChannels))
            let outFrames = Int(out.mDataByteSize) / (4 * outCh)
            let op = od.assumingMemoryBound(to: Float.self)
            guard let inBuf = ins.count > i ? ins[i] : ins.first, let id = inBuf.mData else {
                memset(od, 0, Int(out.mDataByteSize)); continue
            }
            let inCh = max(1, Int(inBuf.mNumberChannels))
            let inFrames = Int(inBuf.mDataByteSize) / (4 * inCh)
            let ip = id.assumingMemoryBound(to: Float.self)
            let frames = min(outFrames, inFrames)
            for f in 0..<frames {
                for c in 0..<outCh {
                    op[f * outCh + c] = ip[f * inCh + min(c, inCh - 1)] * gain
                }
            }
            if frames < outFrames {
                memset(op + frames * outCh, 0, (outFrames - frames) * outCh * 4)
            }
        }
    }

    // MARK: - Lookup

    static func processObjects(bundlePrefix: String) -> [AudioObjectID] {
        var addr = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { string($0, kAudioProcessPropertyBundleID).hasPrefix(bundlePrefix) }
    }

    static func defaultOutputUID() -> String? {
        var addr = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        let uid = string(device, kAudioDevicePropertyDeviceUID)
        return uid.isEmpty ? nil : uid
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioDevices.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.coreAudio(what, status) }
    }

    /// Read on the real-time audio thread; written once before the IO proc starts.
    private final class GainBox: @unchecked Sendable { var value: Float = 1 }
}

public enum TapError: Error, CustomStringConvertible {
    case noProcess, noOutput
    case coreAudio(String, OSStatus)

    public var description: String {
        switch self {
        case .noProcess: return "Chrome has no audio process"
        case .noOutput: return "no output device"
        case .coreAudio(let what, let status): return "Core Audio \(what) failed (\(status))"
        }
    }
}
