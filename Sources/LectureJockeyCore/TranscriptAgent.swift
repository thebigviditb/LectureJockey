import Foundation

/// Follows macOS Now Playing through `media-control stream` (a full snapshot, then
/// diffs) and reports the merged state on every change.
public final class NowPlayingStream: @unchecked Sendable {
    public let executable: String
    private let queue = DispatchQueue(label: "lecturejockey.nowplaying")
    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var onChange: (@Sendable ([String: Any]) -> Void)?
    private var stopped = false

    public init(executable: String) {
        self.executable = executable
    }

    public func start(onChange: @escaping @Sendable ([String: Any]) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            launch()
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            process?.terminate()
        }
    }

    private func launch() {
        guard !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            // The stream should run for as long as LectureJockey does; restart if it dies.
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 2) { self.launch() }
        }
        do { try p.run(); process = p } catch {}
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            Self.merge(line: Data(line), into: &state)
            onChange?(state)
        }
    }

    /// Applies one stream line: `diff: false` replaces the state, `diff: true` updates it.
    static func merge(line: Data, into state: inout [String: Any]) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data" else { return }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        if obj["diff"] as? Bool == true {
            for (k, v) in payload { state[k] = v }
        } else {
            state = payload
        }
    }
}

/// Fetches a YouTube transcript once per video, as soon as Chrome starts playing it,
/// and saves it to the store. Videos already stored, or that failed this session,
/// are not retried.
public final class TranscriptAgent: @unchecked Sendable {
    public let store: TranscriptStore
    public let fetcher: YouTubeTranscript
    private let queue = DispatchQueue(label: "lecturejockey.transcripts")
    private let log: @Sendable (String) -> Void
    private var lastTrigger = ""
    private var failed: Set<String> = []

    public init(store: TranscriptStore = TranscriptStore(), fetcher: YouTubeTranscript = YouTubeTranscript(),
                log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.fetcher = fetcher
        self.log = log
    }

    /// Feed it Now Playing state; it acts when Chrome starts playing a new title.
    public func nowPlayingChanged(_ state: [String: Any]) {
        guard state["bundleIdentifier"] as? String == ChromeDriver.bundleID,
              state["playing"] as? Bool == true else { return }
        let trigger = (state["title"] as? String ?? "") + "|" + String(describing: state["duration"] ?? "")
        queue.async { [self] in
            guard trigger != lastTrigger else { return }
            lastTrigger = trigger
            fetchForPlayingTab()
        }
    }

    /// Call on `queue`.
    private func fetchForPlayingTab() {
        let tab: ChromeTabs.Tab
        do {
            let tabs = try ChromeTabs.all().filter { YouTubeTranscript.videoID(from: $0.url) != nil }
            guard let playing = try tabs.first(where: { try ChromeTabs.run(Self.isPlayingJS, in: $0) == "playing" }) else { return }
            tab = playing
        } catch {
            log("transcript: cannot read Chrome's tabs (\(error))")
            return
        }
        guard let id = YouTubeTranscript.videoID(from: tab.url) else { return }
        let key = YouTubeTranscript.key(for: id)
        guard store.load(key) == nil, !failed.contains(key) else { return }
        do {
            let started = Date()
            let t = try fetcher.fetch(from: tab)
            try store.save(t)
            log("transcript: \(key) \(t.segments.count) lines, \(t.wordCount) words in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            failed.insert(key)
            log("transcript: \(key) not fetched (\(error)); live transcription will cover it")
        }
    }

    public static let isPlayingJS = #"(() => { const v = document.querySelector('video'); return v && !v.paused && !v.ended ? 'playing' : ''; })()"#
}
