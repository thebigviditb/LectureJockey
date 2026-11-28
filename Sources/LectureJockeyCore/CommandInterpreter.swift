import Foundation

/// Turns a dictation no grammar rule matched into player commands with one Claude
/// call (Haiku, on Bedrock). The model sees the video's transcript when there is one
/// and answers only with tool calls, so a new feature is a new tool, not a new label
/// or new number-extraction code.
///
/// The model never produces a timestamp for transcript content: it picks a line
/// number, and the line's start time comes from the transcript file.
public struct CommandInterpreter: Sendable {
    public static let defaultModel = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    /// Seek a little before the chosen line, so the sentence is heard from its start.
    public static let leadIn: Double = 1.5

    public let client: BedrockClient
    public let model: String

    public init(client: BedrockClient, model: String = CommandInterpreter.defaultModel) {
        self.client = client
        self.model = model
    }

    /// Bedrock through an `aws` CLI profile: LJ_AWS_PROFILE (default "intension"),
    /// LJ_AWS_REGION (default us-west-2), LJ_MODEL (default Haiku 4.5).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> CommandInterpreter {
        let creds = try AWSCredentials.fromProfile(env["LJ_AWS_PROFILE"] ?? "intension")
        return CommandInterpreter(client: BedrockClient(credentials: creds, region: env["LJ_AWS_REGION"] ?? "us-west-2"),
                                  model: env["LJ_MODEL"] ?? defaultModel)
    }

    /// The transcript and title for the video a driver is playing: YouTube by the front
    /// tab's video ID. Other videos have none until live transcription exists.
    public static func context(for target: (driver: PlayerDriver, video: ChromeDriver.VideoState),
                               store: TranscriptStore = TranscriptStore()) -> Context {
        var transcript: Transcript?
        if target.driver is ChromeDriver, let url = try? ChromeTabs.frontURL(), let id = YouTubeTranscript.videoID(from: url) {
            transcript = store.load(YouTubeTranscript.key(for: id))
        }
        let v = target.video
        return Context(title: transcript?.title ?? "", duration: v.duration, position: v.time, rate: v.rate,
                       playing: v.playing, transcript: transcript)
    }

    public struct Context: Sendable {
        public var title: String
        public var duration: Double
        public var position: Double
        public var rate: Double
        public var playing: Bool
        public var transcript: Transcript?

        public init(title: String, duration: Double, position: Double, rate: Double, playing: Bool, transcript: Transcript?) {
            self.title = title
            self.duration = duration
            self.position = position
            self.rate = rate
            self.playing = playing
            self.transcript = transcript
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
        let reply = try client.converse(model: model, body: Self.requestBody(utterance, context: context))
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
        - "A bit" is about 10 seconds; "a little faster/slower" is a step of 0.25.
        - If the request needs content the transcript does not cover, or there is no transcript, call \
        no_action with kind cannot_do and say what is missing. Never guess a time for content.
        - If the text is not addressed to the player (conversation, notes, an opinion about the video, \
        or words that sound like they came from the video itself), call no_action with kind \
        not_a_command. When unsure, do not act.
        - Always answer with at least one tool call, never with text alone.
        """

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func transcriptBlock(_ context: Context) -> String {
        guard let t = context.transcript, !t.segments.isEmpty else {
            return "No transcript is available for this video yet."
        }
        let lines = t.segments.enumerated().map { "[\($0.offset)] \(clock($0.element.start)) \($0.element.text)" }
        let covered = t.covered.map { "\(clock($0[0]))-\(clock($0[1]))" }.joined(separator: ", ")
        return "Transcript of \"\(t.title)\" (video time; covers \(covered)):\n" + lines.joined(separator: "\n")
    }

    static func requestBody(_ utterance: String, context: Context) -> [String: Any] {
        let state = "Player: \(context.playing ? "playing" : "paused") at \(clock(context.position)) of \(clock(context.duration)), speed \(Command.format(context.rate))x. Video: \"\(context.title)\"."
        return [
            // A tool call is required: no_action covers "do nothing", so a text-only reply never happens.
            // Instructions and transcript first, then a cache point: they stay the same for
            // every command on this video, so later commands read them from the cache.
            "system": [["text": instructions], ["text": transcriptBlock(context)], ["cachePoint": ["type": "default"]]],
            "messages": [["role": "user", "content": [["text": "\(state)\nSpoken: \"\(utterance)\""]]]],
            "toolConfig": ["tools": tools.map { ["toolSpec": $0] }, "toolChoice": ["any": [String: Any]()]],
            "inferenceConfig": ["maxTokens": 400],
        ]
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
        ["name": "seek_to", "description": "Jump to a time the speaker says out loud, in seconds from the start (\"go to 5 minutes\", \"the middle\" = half the duration). Never for content or topics: use seek_to_line for those.",
         "inputSchema": schema(["seconds": ["type": "number"]], required: ["seconds"])],
        ["name": "seek_to_line", "description": "Jump to the start of a transcript line, by its [number]. The only way to jump to content: a topic, an explanation, the end of the intro.",
         "inputSchema": schema(["line": ["type": "integer"]], required: ["line"])],
        ["name": "pause", "description": "Pause playback.", "inputSchema": schema([:], required: [])],
        ["name": "play", "description": "Play or resume.", "inputSchema": schema([:], required: [])],
        ["name": "no_action", "description": "Do nothing: the text is not a request to the player, or the request cannot be done.",
         "inputSchema": schema(["kind": ["type": "string", "enum": ["not_a_command", "cannot_do"]], "reason": ["type": "string"]],
                               required: ["kind", "reason"])],
    ]

    // MARK: - Tool calls to commands

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
                if let s = number(call.input["seconds"]), s >= 0, s <= end { out.commands.append(.seekTo(s)) }
                else { out.notes.append("dropped seek_to outside the video") }
            case "seek_to_line":
                if let segs = context.transcript?.segments, let i = number(call.input["line"]).map(Int.init), segs.indices.contains(i) {
                    out.commands.append(.seekTo(max(0, segs[i].start - leadIn)))
                } else { out.notes.append("dropped seek_to_line: no such line") }
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
