import CoreAudio
import Foundation

/// CoreAudio queries: which output is active, and whether any microphone is in use.
public enum AudioDevices {
    /// True when the default output is the Mac's built-in speakers (not headphones,
    /// AirPods, a display or an interface), i.e. when the video can leak into the mic.
    public static func outputIsBuiltInSpeakers() -> Bool {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return false }
        guard get(device, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn else {
            return false
        }
        // Built-in output exposes a data source: 'ispk' internal speakers, 'hdpn' headphones.
        if let source = get(device, kAudioDevicePropertyDataSource, UInt32(0), scope: kAudioDevicePropertyScopeOutput) {
            return source == fourCC("ispk")
        }
        return name(device).localizedCaseInsensitiveContains("speaker")
    }

    public static func outputName() -> String {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).map(name) ?? "none"
    }

    /// Every device with input channels.
    static func inputDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { hasInput($0) }
    }

    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        (get(device, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) ?? 0) != 0
    }

    // MARK: - Helpers

    static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let id = get(AudioObjectID(kAudioObjectSystemObject), selector, AudioObjectID(0))
        return id == 0 ? nil : id
    }

    private static func get<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func name(_ device: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Reports when any microphone starts or stops being used by any app.
/// Wispr Flow opens the mic only while it records, so "no mic in use" means it stopped.
public final class MicMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onChange: @Sendable (Bool) -> Void
    private var devices: [AudioObjectID] = []
    private var listener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    public private(set) var anyRunning = false

    public init(queue: DispatchQueue, onChange: @escaping @Sendable (Bool) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// Call on `queue`.
    public func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        self.listener = listener
        let devicesChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }
        deviceListListener = devicesChanged
        var addr = AudioDevices.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, devicesChanged)
        attach()
    }

    /// Call on `queue`. Listens on every input device, so a non-default mic (AirPods) counts too.
    private func attach() {
        guard let listener else { return }
        var addr = AudioDevices.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for d in devices { AudioObjectRemovePropertyListenerBlock(d, &addr, queue, listener) }
        devices = AudioDevices.inputDevices()
        for d in devices { AudioObjectAddPropertyListenerBlock(d, &addr, queue, listener) }
        anyRunning = devices.contains(where: AudioDevices.isRunningSomewhere)
    }

    private func refresh() {
        let now = devices.contains(where: AudioDevices.isRunningSomewhere)
        guard now != anyRunning else { return }
        anyRunning = now
        onChange(now)
    }
}
