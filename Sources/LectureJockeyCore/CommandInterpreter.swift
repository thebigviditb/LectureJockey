import Foundation

/// Turns a dictation no grammar rule matched into player commands with one Claude
/// call (Haiku, on Bedrock). The model sees the video's transcript when there is one
/// and answers only with tool calls, so a new feature is a new tool, not a new label
/// or new number-extraction code.
///
/// The model never produces a timestamp for transcript content: it picks a line
/// number, and the line's start time comes from the transcript file.
public struct CommandInterpreter: Sendable {
    /// Seek a little before the chosen line, so the sentence is heard from its start.
    public static let leadIn: Double = 1.5

    public let backend: ModelBackend
    public var model: String { backend.label }

    public init(backend: ModelBackend) {
        self.backend = backend
    }

    /// The backend the settings name (see `Backends`); nil when LJ_BACKEND=none.
    public static func fromEnvironment(_ env: [String: String] = Settings.load()) throws -> CommandInterpreter? {
        try Backends.fromEnvironment(env).map(CommandInterpreter.init(backend:))
    }

    /// The transcript and title for the video a driver is playing: YouTube by the front
    /// tab's video ID. Other videos have none until live transcription exists.
    public static func context(for target: (driver: PlayerDriver, video: ChromeDriver.VideoState),
                               history: PositionHistory? = nil, nowPlaying: NowPlayingDriver? = nil,
                               store: TranscriptStore = TranscriptStore()) -> Context {
        var transcript: Transcript?
        if target.driver is ChromeDriver, let url = try? ChromeTabs.frontURL(), let id = YouTubeTranscript.videoID(from: url) {
            transcript = store.load(YouTubeTranscript.key(for: id))
        }
        // Otherwise what live transcription has heard so far, by Now Playing's name for the video.
        if transcript == nil, let np = nowPlaying, let current = try? np.titleAndDuration() {
            transcript = store.load(Transcript.liveKey(title: current.title, duration: current.duration))
        }
        let v = target.video
        let point = history?.peek(video: PositionHistory.videoID(driver: target.driver.name, duration: v.duration))
        return Context(title: transcript?.title ?? "", duration: v.duration, position: v.time, rate: v.rate,
                       playing: v.playing, transcript: transcript,
                       returnPoint: point.map { ($0.time, Date().timeIntervalSince($0.at)) })
    }

    public struct Context: Sendable {
        public var title: String
        public var duration: Double
        public var position: Double
        public var rate: Double
        public var playing: Bool
        public var transcript: Transcript?
        /// Where the last jump came from, and how many seconds ago it was made.
        public var returnPoint: (time: Double, age: Double)?

        public init(title: String, duration: Double, position: Double, rate: Double, playing: Bool, transcript: Transcript?,
                    returnPoint: (time: Double, age: Double)? = nil) {
            self.title = title
            self.duration = duration
            self.position = position
            self.rate = rate
            self.playing = playing
            self.transcript = transcript
            self.returnPoint = returnPoint
        }
    }

    public struct Result: Sendable {
        public var commands: [Command]
        /// Why nothing was done (no_action), or why a tool call was dropped.
        public var notes: [String]
        public var calls: [String]
        public var usage: BedrockClient.Usage
        public var latencyMs: Int
    }

    public func interpret(_ utterance: String, context: Context) throws -> Result {
        let reply = try backend.complete(Self.request(utterance, context: context))
        var result = Self.commands(from: reply.toolUses, context: context)
        result.usage = reply.usage
        result.latencyMs = reply.latencyMs
        if reply.toolUses.isEmpty { result.notes.append("no tool call (\(reply.stopReason)): \(reply.text.prefix(200))") }
        return result
    }

    // MARK: - Request

    static let instructions = """
        You control the video player of someone watching a video. They dictate with a speech-to-text \
        tool; the text below was typed into the browser while the video was open. Decide whether it is \
        a request to control playback, and answer only with tool calls.

        - If it is a request, call the tools that carry it out, in order (for example a jump, then a speed).
        - For requests about content (a topic, "go back to where he explains X", "skip the intro"), use \
        seek_to_line with a line number from the transcript. "Skip the intro" means the first line where \
        the main content starts, after greetings, previews, sponsor reads and channel housekeeping. \
        Prefer the line where a topic is introduced over a later mention, unless they ask for a later one.
        - When the speaker gives an explicit time, amount or speed ("jump to two minutes in", "back 30 \
        seconds", "2x"), use it directly; that needs no transcript. If they also say why ("skip the \
        intro, jump to two minutes in"), the time is how to do it, not a conflict.
        - After a jump, "go back", "go back to where I was", "okay, I'm good" or "that's enough" usually \
        mean: return to where they jumped from (return_to_previous). Use it only when a previous position \
        is listed. "Go back" with an amount or a place ("go back 30 seconds", "go back to the start") is a \
        normal seek. With no previous position, a bare "go back" means back about 10 seconds.
        - "A bit" is about 10 seconds; "a little faster/slower" is a step of 0.25.
        - If the request needs content the transcript does not cover, or there is no transcript, call \
        no_action with kind cannot_do and say what is missing. Never guess a time for content.
        - If the text is not addressed to the player (conversation, notes, an opinion about the video, \
        or words that sound like they came from the video itself), call no_action with kind \
        not_a_command. When unsure, do not act.
        - Always answer with at least one tool call, never with text alone.
        """

    public static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func ago(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) seconds ago" : s < 3600 ? "\(s / 60) minutes ago" : "\(s / 3600) hours ago"
    }

    static func transcriptBlock(_ context: Context) -> String {
        guard let t = context.transcript, !t.segments.isEmpty else {
            return "No transcript is available for this video yet."
        }
        let lines = t.segments.enumerated().map { "[\($0.offset)] \(clock($0.element.start)) \($0.element.text)" }
        let covered = t.covered.map { "\(clock($0[0]))-\(clock($0[1]))" }.joined(separator: ", ")
        return "Transcript of \"\(t.title)\" (video time; covers \(covered)):\n" + lines.joined(separator: "\n")
    }

    /// The Bedrock form of the request, as sent (kept for tests and debugging).
    static func requestBody(_ utterance: String, context: Context) -> [String: Any] {
        BedrockBackend.body(request(utterance, context: context))
    }

    static func request(_ utterance: String, context: Context) -> ModelRequest {
        var state = "Player: \(context.playing ? "playing" : "paused") at \(clock(context.position)) of \(clock(context.duration)), speed \(Command.format(context.rate))x. Video: \"\(context.title)\"."
        if let p = context.returnPoint {
            state += "\nPrevious position: \(clock(p.time)) (they jumped away from it \(ago(p.age)))."
        } else {
            state += "\nPrevious position: none."
        }
        // Instructions and transcript stay the same for every command on a video, so
        // backends put them first, where a prompt cache can reuse them.
        return ModelRequest(instructions: instructions, transcript: transcriptBlock(context),
                            user: "\(state)\nSpoken: \"\(utterance)\"", tools: tools)
    }

    static func schema(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["json": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    /// A constant, never mutated.
    nonisolated(unsafe) static let tools: [[String: Any]] = [
        ["name": "set_rate", "description": "Set the playback speed, e.g. 2 for 2x. 0.25 to 4.",
         "inputSchema": schema(["rate": ["type": "number"]], required: ["rate"])],
        ["name": "change_rate", "description": "Change the speed by a step: positive is faster, negative slower.",
         "inputSchema": schema(["by": ["type": "number"]], required: ["by"])],
        ["name": "seek_by", "description": "Move by a number of seconds from the current position: negative goes back.",
         "inputSchema": schema(["seconds": ["type": "number"]], required: ["seconds"])],
        ["name": "seek_to", "description": "Jump to a time the speaker says out loud (\"go to 5 minutes\" = 5:00, \"the middle\" = half the duration). Never for content or topics: use seek_to_line for those.",
         "inputSchema": schema(["time": ["type": "string", "description": "Time from the start as M:SS or H:MM:SS, e.g. 11:10 or 1:02:30. Plain seconds also work, e.g. 670."]],
                               required: ["time"])],
        ["name": "seek_to_line", "description": "Jump to the start of a transcript line, by its [number]. The only way to jump to content: a topic, an explanation, the end of the intro.",
         "inputSchema": schema(["line": ["type": "integer"]], required: ["line"])],
        ["name": "return_to_previous", "description": "Go back to the previous position listed (where the last jump came from).",
         "inputSchema": schema([:], required: [])],
        ["name": "pause", "description": "Pause playback.", "inputSchema": schema([:], required: [])],
        ["name": "play", "description": "Play or resume.", "inputSchema": schema([:], required: [])],
        ["name": "no_action", "description": "Do nothing: the text is not a request to the player, or the request cannot be done.",
         "inputSchema": schema(["kind": ["type": "string", "enum": ["not_a_command", "cannot_do"]], "reason": ["type": "string"]],
                               required: ["kind", "reason"])],
    ]

    // MARK: - Tool calls to commands

    /// "11:10" -> 670, "1:02:30" -> 3750, "670" or 670 -> 670; nil for anything else.
    static func timeValue(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !(v is Bool) { return n.doubleValue }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let values = parts.map { $0! }
        if values.count > 1, values.dropFirst().contains(where: { $0 >= 60 }) { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// Validates every call; anything out of range is dropped with a note rather than run.
    static func commands(from calls: [BedrockClient.ToolUse], context: Context) -> Result {
        var out = Result(commands: [], notes: [], calls: [], usage: .init(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0), latencyMs: 0)
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        let end = context.duration > 0 ? context.duration : .infinity
        for call in calls {
            let args = call.input.isEmpty ? "" : (try? String(decoding: JSONSerialization.data(withJSONObject: call.input, options: .sortedKeys), as: UTF8.self)) ?? ""
            out.calls.append("\(call.name)\(args)")
            switch call.name {
            case "set_rate":
                if let r = number(call.input["rate"]), (0.25...4).contains(r) { out.commands.append(.setRate(r)) }
                else { out.notes.append("dropped set_rate outside 0.25-4") }
            case "change_rate":
                if let d = number(call.input["by"]), abs(d) <= 2, d != 0 { out.commands.append(.changeRate(by: d)) }
                else { out.notes.append("dropped change_rate") }
            case "seek_by":
                if let s = number(call.input["seconds"]), s != 0, abs(s) <= 6 * 3600 { out.commands.append(.seek(by: s)) }
                else { out.notes.append("dropped seek_by") }
            case "seek_to":
                // Small models think in minutes:seconds, so "11:10" is accepted as well as 670.
                if let s = timeValue(call.input["time"] ?? call.input["seconds"]), s >= 0, s <= end { out.commands.append(.seekTo(s)) }
                else { out.notes.append("dropped seek_to: not a time in the video") }
            case "seek_to_line":
                if let segs = context.transcript?.segments, let i = number(call.input["line"]).map(Int.init), segs.indices.contains(i) {
                    out.commands.append(.seekTo(max(0, segs[i].start - leadIn)))
                } else { out.notes.append("dropped seek_to_line: no such line") }
            case "return_to_previous":
                if context.returnPoint != nil { out.commands.append(.returnToPrevious) }
                else { out.notes.append("dropped return_to_previous: no previous position") }
            case "pause": out.commands.append(.pause)
            case "play": out.commands.append(.play)
            case "no_action":
                out.notes.append("\(call.input["kind"] as? String ?? "no_action"): \(call.input["reason"] as? String ?? "")")
            default:
                out.notes.append("unknown tool \(call.name)")
            }
        }
        return out
    }
}
