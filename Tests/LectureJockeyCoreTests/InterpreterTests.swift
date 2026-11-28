import Foundation
import Testing
@testable import LectureJockeyCore

struct SigV4Tests {
    /// AWS's published Signature Version 4 example (IAM ListUsers, 2015-08-30).
    @Test func matchesAWSsPublishedExample() {
        let signer = SigV4(credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                           region: "us-east-1", service: "iam")
        let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
        let h = signer.sign(method: "GET", host: "iam.amazonaws.com", path: "/", query: "Action=ListUsers&Version=2010-05-08",
                            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"], body: Data(), date: date)
        #expect(h["x-amz-date"] == "20150830T123600Z")
        #expect(h["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    }

    @Test func encodesModelIDsInThePath() {
        #expect(SigV4.uriEncode("us.anthropic.claude-haiku-4-5-20251001-v1:0") == "us.anthropic.claude-haiku-4-5-20251001-v1%3A0")
    }

    @Test func includesTheSessionToken() {
        let s = SigV4(credentials: AWSCredentials(accessKeyID: "A", secretAccessKey: "S", sessionToken: "T"), region: "us-west-2", service: "bedrock")
        let h = s.sign(method: "POST", host: "h", path: "/x", headers: [:], body: Data())
        #expect(h["x-amz-security-token"] == "T")
        #expect(h["Authorization"]?.contains("SignedHeaders=host;x-amz-date;x-amz-security-token") == true)
    }
}

struct InterpreterMappingTests {
    let transcript = Transcript.fromCaptions(key: "youtube:x", title: "Primes", duration: 1340,
                                             starts: [(3, "intro"), (61, "the pattern"), (878, "Dirichlet's theorem")])
    var context: CommandInterpreter.Context {
        .init(title: "Primes", duration: 1340, position: 300, rate: 1, playing: true, transcript: transcript)
    }

    func run(_ calls: [(String, [String: Any])]) -> CommandInterpreter.Result {
        CommandInterpreter.commands(from: calls.map { BedrockClient.ToolUse(name: $0.0, input: $0.1) }, context: context)
    }

    @Test func mapsEachTool() {
        let r = run([("seek_to_line", ["line": 2]), ("set_rate", ["rate": 1.5]), ("play", [:])])
        #expect(r.commands == [.seekTo(878 - CommandInterpreter.leadIn), .setRate(1.5), .play])
        #expect(run([("seek_by", ["seconds": -30])]).commands == [.seek(by: -30)])
        #expect(run([("seek_to", ["seconds": 670])]).commands == [.seekTo(670)])
        #expect(run([("change_rate", ["by": 0.25])]).commands == [.changeRate(by: 0.25)])
        #expect(run([("pause", [:])]).commands == [.pause])
    }

    @Test func timesForContentComeFromTheTranscriptNotTheModel() {
        // Line 1 starts at 61 s; the model only names the line.
        #expect(run([("seek_to_line", ["line": 1])]).commands == [.seekTo(61 - CommandInterpreter.leadIn)])
        #expect(run([("seek_to_line", ["line": 0])]).commands == [.seekTo(1.5)])
    }

    @Test func dropsCallsOutOfRange() {
        #expect(run([("seek_to_line", ["line": 99])]).commands.isEmpty)
        #expect(run([("set_rate", ["rate": 10])]).commands.isEmpty)
        #expect(run([("seek_to", ["seconds": 5000])]).commands.isEmpty, "past the end of the video")
        #expect(run([("seek_to", ["seconds": -5])]).commands.isEmpty)
        #expect(run([("bogus", [:])]).notes == ["unknown tool bogus"])
    }

    @Test func noActionDoesNothingAndSaysWhy() {
        let r = run([("no_action", ["kind": "not_a_command", "reason": "a remark about the video"])])
        #expect(r.commands.isEmpty)
        #expect(r.notes == ["not_a_command: a remark about the video"])
    }

    @Test func requestCachesInstructionsAndTranscriptAndPutsTheUtteranceAfter() throws {
        let body = CommandInterpreter.requestBody("skip the intro", context: context)
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 3)
        #expect((system[1]["text"] as? String)?.contains("[2] 14:38 Dirichlet's theorem") == true)
        #expect(system[2]["cachePoint"] != nil, "the cache point follows the transcript")
        let messages = try #require(body["messages"] as? [[String: Any]])
        let text = ((messages[0]["content"] as? [[String: Any]])?[0]["text"] as? String) ?? ""
        #expect(text.contains("Spoken: \"skip the intro\""))
        #expect(text.contains("playing at 5:00 of 22:20"))
    }

    @Test func saysWhenThereIsNoTranscript() {
        var c = context
        c.transcript = nil
        #expect(CommandInterpreter.transcriptBlock(c) == "No transcript is available for this video yet.")
    }

    @Test func parsesAConverseResponse() throws {
        let json = """
            {"output":{"message":{"role":"assistant","content":[{"toolUse":{"toolUseId":"t1","name":"seek_to_line","input":{"line":7}}}]}},
             "stopReason":"tool_use","usage":{"inputTokens":376,"outputTokens":56,"cacheReadInputTokens":7536,"cacheWriteInputTokens":0},
             "metrics":{"latencyMs":603}}
            """
        let r = try BedrockClient.parse(Data(json.utf8))
        #expect(r.toolUses.map(\.name) == ["seek_to_line"])
        #expect(r.toolUses[0].input["line"] as? Int == 7)
        #expect(r.usage == .init(inputTokens: 376, outputTokens: 56, cacheReadTokens: 7536, cacheWriteTokens: 0))
        #expect(r.latencyMs == 603)
    }
}

/// Live phrase list for the model. Calls Bedrock (the intension profile), so it runs only
/// with `LJ_LLM_EVAL=1 swift test --filter InterpreterEval`. Add phrases with each feature.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LJ_LLM_EVAL"] == "1"))
struct InterpreterEval {
    struct Case: Sendable {
        let text: String
        let transcript: String?
        let playing: Bool
        let check: @Sendable ([Command]) -> Bool
        let want: String
    }

    static func near(_ c: Command?, seekTo target: Double, within: Double) -> Bool {
        if case .seekTo(let t)? = c { return abs(t - target) <= within }
        return false
    }

    static let prime = "youtube:EK32jo7i5LQ"
    static let cases: [Case] = [
        .init(text: "Make it a little faster", transcript: nil, playing: true, check: { $0 == [.changeRate(by: 0.25)] }, want: "rate +0.25"),
        .init(text: "Hmm, can you take me back like half a minute", transcript: nil, playing: true, check: { $0 == [.seek(by: -30)] }, want: "seek -30"),
        .init(text: "Bump it up to double speed", transcript: nil, playing: true, check: { $0 == [.setRate(2)] }, want: "rate 2x"),
        .init(text: "Let's hold it there for a sec", transcript: nil, playing: true, check: { $0 == [.pause] }, want: "pause"),
        .init(text: "Skip the intro, jump to two minutes in", transcript: nil, playing: true, check: { $0 == [.seekTo(120)] }, want: "seek to 120"),
        .init(text: "Back up ten seconds", transcript: nil, playing: true, check: { $0 == [.seek(by: -10)] }, want: "seek -10"),
        .init(text: "Take it from the top", transcript: nil, playing: true, check: { $0 == [.seekTo(0)] || $0 == [.seekTo(0), .play] }, want: "seek to 0"),
        .init(text: "Wait, what did he just say? Go back a bit", transcript: nil, playing: true,
              check: { if case .seek(let s)? = $0.first, $0.count == 1 { return (-20 ... -5).contains(s) } else { return false } }, want: "seek back 5-20"),
        .init(text: "Crank it to one and a half", transcript: nil, playing: true, check: { $0 == [.setRate(1.5)] }, want: "rate 1.5x"),
        .init(text: "Can we go back to regular speed", transcript: nil, playing: true, check: { $0 == [.setRate(1)] }, want: "rate 1x"),
        .init(text: "Okay keep going", transcript: nil, playing: false, check: { $0 == [.play] }, want: "play"),
        .init(text: "Jump ahead like 30 seconds", transcript: nil, playing: true, check: { $0 == [.seek(by: 30)] }, want: "seek +30"),
        .init(text: "Go to the middle of the video.", transcript: nil, playing: true, check: { near($0.first, seekTo: 670, within: 5) && $0.count == 1 }, want: "seek to ~670"),
        // Must not act.
        .init(text: "Remind me to email Sarah tomorrow", transcript: nil, playing: true, check: { $0.isEmpty }, want: "nothing"),
        .init(text: "Okay cool, that makes sense", transcript: prime, playing: true, check: { $0.isEmpty }, want: "nothing"),
        .init(text: "I think the speed of light is constant", transcript: nil, playing: true, check: { $0.isEmpty }, want: "nothing"),
        .init(text: "Go back to the beginning of the relationship if you're ever going to get in a relationship.", transcript: nil, playing: true, check: { $0.isEmpty }, want: "nothing"),
        .init(text: "side of a relationship, she just met this guy.", transcript: nil, playing: true, check: { $0.isEmpty }, want: "nothing"),
        // Transcript.
        .init(text: "Skip the intro", transcript: prime, playing: true, check: { near($0.first, seekTo: 45, within: 35) }, want: "seek to 0:10-1:20"),
        .init(text: "go back to where he explains Dirichlet's theorem", transcript: prime, playing: true,
              check: { near($0.first, seekTo: 877, within: 30) || near($0.first, seekTo: 260, within: 15) }, want: "seek to ~14:37 or ~4:20"),
        .init(text: "skip to the part about pi approximations and play it at 1.5x", transcript: prime, playing: true,
              // Two right answers: 22/7 at 7:13-7:40, or 710/113 and 355/113 at 10:59-11:40.
              check: { (near($0.first, seekTo: 445, within: 25) || near($0.first, seekTo: 680, within: 25)) && $0.contains(.setRate(1.5)) },
              want: "seek to ~7:20 or ~11:20, rate 1.5x"),
        .init(text: "go to where he talks about quantum computing", transcript: prime, playing: true, check: { $0.isEmpty }, want: "nothing (not in the video)"),
    ]

    @Test func everyPhraseDoesWhatItShould() async throws {
        let interpreter = try CommandInterpreter.fromEnvironment()
        let store = TranscriptStore()
        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for c in Self.cases {
                group.addTask {
                    let t = c.transcript.flatMap { store.load($0) }
                    if c.transcript != nil, t == nil { return "\"\(c.text)\": transcript \(c.transcript!) not saved; run transcript fetch" }
                    let ctx = CommandInterpreter.Context(title: t?.title ?? "A lecture", duration: t?.duration ?? 1340, position: 300,
                                                         rate: 1, playing: c.playing, transcript: t)
                    do {
                        let r = try interpreter.interpret(c.text, context: ctx)
                        return c.check(r.commands) ? nil
                            : "\"\(c.text)\": got [\(r.commands.map(\.summary).joined(separator: ", "))] \(r.notes), want \(c.want)"
                    } catch { return "\"\(c.text)\": \(error)" }
                }
            }
            for await f in group { if let f { failures.append(f) } }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(Self.cases.count) failed:\n\(failures.joined(separator: "\n"))")
    }
}
