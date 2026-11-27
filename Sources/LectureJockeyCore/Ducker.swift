import Foundation

/// Lowers a playing video's volume while Wispr Flow records over the built-in
/// speakers, so the mic hears you and not the video, then puts it back.
///
/// Restores on the first of: the mic going idle (Wispr stopped recording), Wispr
/// finalizing the row, the mic never starting (a cancelled recording), a safety
/// cap, or `restoreNow()` at exit. Wispr leaves rows of cancelled recordings
/// unfinalized forever, so the row alone cannot be trusted to end a duck.
public final class Ducker: @unchecked Sendable {
    public protocol Volume: Sendable {
        /// Lowers the playing video to `level` if it is louder; returns what to restore, or nil if nothing changed.
        func duck(to level: Double) -> DuckToken?
        func restore(_ token: DuckToken)
    }

    public struct Config: Sendable {
        public var level = 0.10
        /// A recording whose mic is not in use by then was cancelled.
        public var micStartGrace: TimeInterval = 2
        public var maxDuration: TimeInterval = 600
        public init() {}
    }

    public let queue: DispatchQueue
    private let volume: Volume
    private let speakersActive: @Sendable () -> Bool
    private let config: Config
    private let log: @Sendable (String) -> Void
    private var active: (token: DuckToken, recording: String, generation: Int)?
    private var micRunning = false
    private var micSeen = false
    private var generation = 0

    public init(
        volume: Volume, speakersActive: @escaping @Sendable () -> Bool, config: Config = Config(),
        queue: DispatchQueue = DispatchQueue(label: "lecturejockey.ducker"),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.volume = volume
        self.speakersActive = speakersActive
        self.config = config
        self.queue = queue
        self.log = log
    }

    public var isDucked: Bool { queue.sync { active != nil } }

    public func recordingStarted(_ id: String) {
        queue.async { [self] in
            guard active == nil else { return }
            guard speakersActive() else { log("duck: skip, output is not the built-in speakers"); return }
            guard let token = volume.duck(to: config.level) else { return }
            generation += 1
            let gen = generation
            active = (token, id, gen)
            micSeen = micRunning
            log("duck: video volume \(Int((token.previous * 100).rounded()))% -> \(Int(config.level * 100))%")
            queue.asyncAfter(deadline: .now() + config.micStartGrace) { [self] in
                if active?.generation == gen, !micSeen { restore("mic never started, recording cancelled") }
            }
            queue.asyncAfter(deadline: .now() + config.maxDuration) { [self] in
                if active?.generation == gen { restore("safety cap") }
            }
        }
    }

    public func recordingFinished(_ id: String) {
        queue.async { [self] in
            if active?.recording == id { restore("Wispr finished the recording") }
        }
    }

    public func micChanged(running: Bool) {
        queue.async { [self] in
            micRunning = running
            if running { micSeen = true; return }
            if active != nil, micSeen { restore("mic idle, Wispr stopped recording") }
        }
    }

    /// Restores synchronously; for exit.
    public func restoreNow() {
        queue.sync { if active != nil { restore("exiting") } }
    }

    private func restore(_ why: String) {
        guard let current = active else { return }
        active = nil
        micSeen = false
        volume.restore(current.token)
        log("duck: restored (\(why))")
    }
}

/// Chrome's front tab as the `Ducker.Volume`.
public struct ChromeVolume: Ducker.Volume {
    public let driver: ChromeDriver
    public let log: @Sendable (String) -> Void

    public init(driver: ChromeDriver = ChromeDriver(), log: @escaping @Sendable (String) -> Void) {
        self.driver = driver
        self.log = log
    }

    public func duck(to level: Double) -> DuckToken? {
        do { return try driver.duck(to: level) } catch { log("duck: error: \(error)"); return nil }
    }

    public func restore(_ token: DuckToken) {
        do { try driver.restore(token) } catch { log("duck: restore error: \(error)") }
    }
}

/// What a duck changed, so it can be put back on the same video.
public struct DuckToken: Sendable, Equatable {
    public let window: Int
    public let tab: Int
    /// The volume before the duck, and the level it was lowered to.
    public let previous: Double
    public let level: Double
    public init(window: Int, tab: Int, previous: Double, level: Double) {
        self.window = window
        self.tab = tab
        self.previous = previous
        self.level = level
    }
}
