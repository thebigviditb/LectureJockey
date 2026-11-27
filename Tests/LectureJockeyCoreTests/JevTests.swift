import Foundation
import Testing
@testable import LectureJockeyCore

struct SlotsTests {
    func words(_ s: String) -> [String] { CommandParser.normalize(s) }

    @Test(arguments: [
        ("take me back like half a minute", 30.0),
        ("jump ahead like 30 seconds", 30),
        ("go back two minutes", 120),
        ("rewind a minute and 15 seconds", 75),
        ("skip forward thirty five seconds", 35),
    ])
    func durations(_ text: String, _ secs: Double) {
        #expect(Slots.duration(words(text)) == secs)
    }

    @Test func noDurationWhenNoneIsSaid() {
        #expect(Slots.duration(words("go back a bit")) == nil)
    }

    @Test(arguments: [
        ("skip the intro, jump to two minutes in", 120.0),
        ("take me to 2:30", 150),
        ("go to 1:02:30 please", 3750),
        ("jump to minute 12", 720),
    ])
    func timestamps(_ text: String, _ secs: Double) {
        #expect(Slots.timestamp(words(text)) == secs)
    }

    @Test(arguments: [
        ("bump it up to double speed", 2.0),
        ("crank it to one and a half", 1.5),
        ("make it 1.25x", 1.25),
        ("play at half speed", 0.5),
        ("three times as fast", 3),
    ])
    func rates(_ text: String, _ rate: Double) {
        #expect(Slots.rate(words(text)) == rate)
    }

    @Test func rejectsRatesOutOfRange() {
        #expect(Slots.rate(words("make it 10x")) == nil)
    }

    @Test func percentages() {
        #expect(Slots.percent(words("go to 75% of the way")) == 75)
        #expect(Slots.percent(words("skip to 40 percent")) == 40)
        #expect(Slots.percent(words("go to 140 percent")) == nil)
    }
}

struct JevMappingTests {
    let jev = JevClassifier(apiKey: "test")

    func answer(_ i: JevClassifier.Intent, _ c: Double = 0.99, _ p: JevClassifier.Position = .none) -> JevClassifier.Answer {
        .init(intent: i, confidence: c, position: p)
    }

    @Test func mapsConfidentAnswersToCommands() {
        #expect(jev.command(for: answer(.seekToPosition, 1, .middle), text: "Go to the middle of the video.") == .seekToFraction(0.5))
        #expect(jev.command(for: answer(.seekBack), text: "take me back like half a minute") == .seek(by: -30))
        #expect(jev.command(for: answer(.seekBack), text: "go back a bit") == .seek(by: -Slots.defaultSeek))
        #expect(jev.command(for: answer(.seekForward), text: "jump ahead like 30 seconds") == .seek(by: 30))
        #expect(jev.command(for: answer(.setRate), text: "bump it up to double speed") == .setRate(2))
        #expect(jev.command(for: answer(.seekToTime), text: "jump to two minutes in") == .seekTo(120))
        #expect(jev.command(for: answer(.normalSpeed), text: "regular speed please") == .setRate(1))
        #expect(jev.command(for: answer(.faster), text: "a little faster") == .changeRate(by: CommandParser.rateStep))
        #expect(jev.command(for: answer(.pause), text: "hold on") == .pause)
    }

    @Test func aPercentageInTheTextBeatsThePositionChoice() {
        #expect(jev.command(for: answer(.seekToPosition, 1, .threeQuarters), text: "go to 80% of the way") == .seekToFraction(0.8))
    }

    @Test func doesNotActBelowTheThreshold() {
        // From the eval: "Go back to the beginning of the relationship..." came back seek 0.75.
        #expect(jev.command(for: answer(.seekToPosition, 0.75, .beginning), text: "go back to the beginning of the relationship") == nil)
    }

    @Test func doesNotActWithoutTheNumberItNeeds() {
        #expect(jev.command(for: answer(.setRate), text: "change the speed") == nil)
        #expect(jev.command(for: answer(.seekToTime), text: "jump to the good part") == nil)
        #expect(jev.command(for: answer(.seekToPosition, 1, .none), text: "go somewhere") == nil)
    }

    @Test func notACommandNeverActs() {
        #expect(jev.command(for: answer(.notACommand, 1), text: "okay cool, that makes sense") == nil)
    }

    @Test func parsesTheResponseShape() throws {
        let body = """
            {"model":"jev-1.14.0","answers":{"intent":{"type":"choice","choice":"seek_to_position","confidence":1.0,
            "probabilities":{"seek_to_position":1.0}},"position":{"type":"choice","choice":"middle","confidence":0.97,
            "probabilities":{"middle":0.97}}},"usage":{"input_tokens":568,"output_tokens":108}}
            """
        let a = try JevClassifier.parse(Data(body.utf8))
        #expect(a == .init(intent: .seekToPosition, confidence: 1.0, position: .middle))
    }

    @Test func requestListsEveryChoice() throws {
        let body = JevClassifier.requestBody(for: "go to the middle")
        let questions = try #require(body["questions"] as? [String: [String: Any]])
        let intents = try #require(questions["intent"]?["criteria"] as? [String: String])
        #expect(Set(intents.keys) == Set(JevClassifier.Intent.allCases.map(\.rawValue)))
        #expect((body["state"] as? String)?.contains("go to the middle") == true)
    }
}

struct GateAskTests {
    @Test func unmatchedPhraseInChromeAsksTheClassifier() {
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let ts = f.string(from: now.addingTimeInterval(-3)) + " +00:00"
        let d = Dictation(id: "x", timestamp: ts, app: ChromeDriver.bundleID, url: "youtube.com",
                          text: "Bump it up to double speed", status: "formatted", duration: 2)
        #expect(Gate.precheck(d, now: now) == .ask)

        let elsewhere = Dictation(id: "y", timestamp: ts, app: "com.microsoft.VSCode", url: "",
                                  text: "Bump it up to double speed", status: "formatted", duration: 2)
        #expect(Gate.precheck(elsewhere, now: now) == .skip("not a command"), "dictation in other apps is never sent to Jev")
    }
}

/// The phrase list that sets the threshold. Calls the real Jev API, so it runs only with
/// `LJ_JEV_EVAL=1 swift test --filter JevEval`. Add phrases here with each new feature.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LJ_JEV_EVAL"] == "1"))
struct JevEval {
    static let cases: [(String, Command?)] = [
        ("Go to the middle of the video.", .seekToFraction(0.5)),
        ("Make it a little faster", .changeRate(by: 0.25)),
        ("Hmm, can you take me back like half a minute", .seek(by: -30)),
        ("Bump it up to double speed", .setRate(2)),
        ("Let's hold it there for a sec", .pause),
        ("Skip the intro, jump to two minutes in", .seekTo(120)),
        ("Back up ten seconds", .seek(by: -10)),
        ("Take it from the top", .seekToFraction(0)),
        ("Wait, what did he just say? Go back a bit", .seek(by: -10)),
        ("Crank it to one and a half", .setRate(1.5)),
        ("Can we go back to regular speed", .setRate(1)),
        ("Okay keep going", .play),
        ("Skip to about two thirds through", .seekToFraction(2.0 / 3)),
        ("Jump ahead like 30 seconds", .seek(by: 30)),
        ("Go to 75% of the way", .seekToFraction(0.75)),
        // Must not act.
        ("This guy talks so slowly", nil),
        ("Remind me to email Sarah tomorrow", nil),
        ("Okay cool, that makes sense", nil),
        ("I think the speed of light is constant", nil),
        ("He's going way too fast", nil),
        ("Go back to the beginning of the relationship if you're ever going to get in a relationship.", nil),
        ("side of a relationship, she just met this guy.", nil),
    ]

    @Test func everyPhraseMapsToTheExpectedCommand() async throws {
        let jev = try #require(JevClassifier.fromKeychain(), "no Jev key in the Keychain")
        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for (text, expected) in Self.cases {
                group.addTask {
                    do {
                        let a = try jev.classify(text)
                        let got = jev.command(for: a, text: text)
                        guard got != expected else { return nil }
                        return "\"\(text)\": got \(got?.summary ?? "nothing") (\(a.intent.rawValue) \(a.confidence)), want \(expected?.summary ?? "nothing")"
                    } catch {
                        return "\"\(text)\": \(error)"
                    }
                }
            }
            for await f in group { if let f { failures.append(f) } }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
