import Foundation

/// Maps wall-clock time to video time from Now Playing reports. Each report says
/// where the video was at a moment and how fast it was moving; between reports the
/// position advances at that rate while playing. Seeks, pauses and speed changes all
/// arrive as new reports.
public struct PlaybackClock: Sendable {
    public struct Anchor: Sendable, Equatable {
        public let wall: Date
        public let elapsed: Double
        public let rate: Double
        public let playing: Bool
    }

    public private(set) var anchors: [Anchor] = []
    public static let keep = 200

    public init() {}

    public mutating func add(_ a: Anchor) {
        if let last = anchors.last, last == a { return }
        anchors.append(a)
        anchors.sort { $0.wall < $1.wall }
        if anchors.count > Self.keep { anchors.removeFirst(anchors.count - Self.keep) }
    }

    /// Adds the anchor a Now Playing state describes, if it has one.
    public mutating func add(nowPlaying state: [String: Any]) {
        guard let elapsed = state["elapsedTime"] as? Double,
              let ts = (state["timestamp"] as? String).flatMap(ISO8601DateFormatter().date(from:)) else { return }
        let playing = state["playing"] as? Bool ?? false
        let rate = state["playbackRate"] as? Double ?? (playing ? 1 : 0)
        add(Anchor(wall: ts, elapsed: elapsed, rate: rate > 0 ? rate : 1, playing: playing))
    }

    /// Video time at `wall`, or nil when the video was paused then (nothing to transcribe).
    public func videoTime(at wall: Date) -> Double? {
        guard let a = anchors.last(where: { $0.wall <= wall }) ?? anchors.first, a.playing else { return nil }
        return max(0, a.elapsed + wall.timeIntervalSince(a.wall) * a.rate)
    }
}

extension Transcript {
    /// Adds a live segment. Text heard again (after a rewind) replaces what overlaps it
    /// instead of duplicating it, and coverage grows to include the segment.
    public mutating func merge(live s: Segment) {
        guard s.end > s.start, !s.text.isEmpty else { return }
        segments.removeAll { old in
            let overlap = min(old.end, s.end) - max(old.start, s.start)
            return overlap > 0.5 * min(old.end - old.start, s.end - s.start)
        }
        segments.append(s)
        segments.sort { $0.start < $1.start }
        covered = Self.union(covered + [[s.start, s.end]], gap: 3)
        updatedAt = Date()
    }

    /// Merges ranges that overlap or sit within `gap` seconds of each other.
    static func union(_ ranges: [[Double]], gap: Double) -> [[Double]] {
        var out: [[Double]] = []
        for r in ranges.filter({ $0.count == 2 }).sorted(by: { $0[0] < $1[0] }) {
            if let last = out.last, r[0] <= last[1] + gap { out[out.count - 1][1] = max(last[1], r[1]) }
            else { out.append(r) }
        }
        return out
    }

    /// The key a live transcript is stored under: what Now Playing calls the video, and its length.
    public static func liveKey(title: String, duration: Double) -> String {
        "nowplaying:\(title)|\(Int(duration.rounded()))"
    }
}

/// Runs live transcription while Chrome plays a video that has no YouTube transcript,
/// and writes what it hears into that video's transcript file.
public final class LiveTranscriptAgent: @unchecked Sendable {
    public let store: TranscriptStore
    private let queue = DispatchQueue(label: "lecturejockey.liveagent")
    private let log: @Sendable (String) -> Void
    private var transcriber: LiveTranscriber?
    private var clock = PlaybackClock()
    private var current: (key: String, title: String, duration: Double)?
    private var heardCount = 0

    public init(store: TranscriptStore = TranscriptStore(), log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.log = log
    }

    /// Feed it every Now Playing state.
    public func nowPlayingChanged(_ state: [String: Any]) {
        let isChrome = state["bundleIdentifier"] as? String == ChromeDriver.bundleID
        var anchorClock = PlaybackClock()
        anchorClock.add(nowPlaying: state)
        let anchor = anchorClock.anchors.first
        let title = state["title"] as? String ?? ""
        let duration = state["duration"] as? Double ?? 0
        let playing = state["playing"] as? Bool ?? false
        queue.async { [self] in
            guard isChrome else { stop("another app is playing"); return }
            if let anchor { clock.add(anchor) }
            guard playing, !title.isEmpty, duration > 0 else { stop("paused"); return }
            let key = Transcript.liveKey(title: title, duration: duration)
            if current?.key == key, transcriber != nil { return }
            if current != nil { stop("a different video") }
            // A video with YouTube's transcript needs no listening.
            if store.all().contains(where: { $0.source == .youtube && $0.title == title }) { return }
            start(key: key, title: title, duration: duration)
        }
    }

    /// On `queue`.
    private func start(key: String, title: String, duration: Double) {
        let t = LiveTranscriber()
        transcriber = t
        current = (key, title, duration)
        heardCount = 0
        log("live transcript: listening to \"\(title)\"")
        Task { [self] in
            do {
                try await t.start(onHeard: { [weak self] heard in
                                      guard let self else { return }
                                      self.queue.async { self.add(heard) }
                                  },
                                  onError: { [weak self] in self?.log("live transcript: \($0)") })
            } catch {
                log("live transcript: cannot start (\(error))")
                queue.async { [self] in if transcriber === t { transcriber = nil; current = nil } }
            }
        }
    }

    /// On `queue`.
    private func stop(_ why: String) {
        guard let t = transcriber else { return }
        transcriber = nil
        if let c = current { log("live transcript: stopped (\(why)), \(heardCount) lines heard for \"\(c.title)\"") }
        current = nil
        Task { await t.stop() }
    }

    /// On `queue`.
    private func add(_ heard: LiveTranscriber.Heard) {
        guard let c = current, let start = clock.videoTime(at: heard.start) else { return }
        let end = clock.videoTime(at: heard.end) ?? start + heard.end.timeIntervalSince(heard.start)
        guard end > start else { return }
        var t = store.load(c.key) ?? Transcript(key: c.key, title: c.title, duration: c.duration, source: .live, segments: [], covered: [])
        t.merge(live: .init(start: start, end: min(end, c.duration), text: heard.text))
        do { try store.save(t) } catch { log("live transcript: cannot save (\(error))") }
        heardCount += 1
        if heardCount == 1 || heardCount % 10 == 0 {
            log("live transcript: \(heardCount) lines for \"\(c.title)\", latest at \(CommandInterpreter.clock(start))")
        }
    }
}
