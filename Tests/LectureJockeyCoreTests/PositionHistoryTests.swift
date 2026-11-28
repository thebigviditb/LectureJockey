import Foundation
import Testing
@testable import LectureJockeyCore

struct PositionHistoryTests {
    let v = PositionHistory.videoID(driver: "chrome", duration: 1340)

    @Test func returnsToTheMostRecentJumpLikeABackButton() {
        let h = PositionHistory()
        h.recordJump(from: 842, video: v)   // jumped from 14:02 to the rays part
        h.recordJump(from: 395, video: v)   // then from there somewhere else
        #expect(h.peek(video: v)?.time == 395)
        #expect(h.popReturn(video: v)?.time == 395)
        #expect(h.popReturn(video: v)?.time == 842, "returning again steps further back")
        #expect(h.popReturn(video: v) == nil)
    }

    @Test func aDifferentVideoStartsFresh() {
        let h = PositionHistory()
        h.recordJump(from: 842, video: v)
        let other = PositionHistory.videoID(driver: "chrome", duration: 474)
        #expect(h.peek(video: other) == nil)
        h.recordJump(from: 10, video: other)
        #expect(h.peek(video: v) == nil, "the old video's history is gone")
        #expect(h.popReturn(video: other)?.time == 10)
    }

    @Test func keepsTheLastTwenty() {
        let h = PositionHistory()
        for i in 0..<25 { h.recordJump(from: Double(i), video: v) }
        var times: [Double] = []
        while let p = h.popReturn(video: v) { times.append(p.time) }
        #expect(times.count == PositionHistory.limit)
        #expect(times.last == 5)
    }

    @Test func onlyMovesOfThePlayheadCount() {
        #expect(PositionHistory.isJump(.seekTo(10)))
        #expect(PositionHistory.isJump(.seek(by: -30)))
        #expect(PositionHistory.isJump(.seekToFraction(0.5)))
        #expect(!PositionHistory.isJump(.setRate(2)))
        #expect(!PositionHistory.isJump(.pause))
        #expect(!PositionHistory.isJump(.returnToPrevious), "returning must not record a new point")
    }
}

struct ReturnGrammarTests {
    @Test(arguments: [
        "Go back to where I was.", "Take me back to where I was", "back to where I left off", "Return to where I was",
        "Take me back", "Where was I?", "Undo that", "Okay, go back to where I was before", "bring me back to where I came from",
    ])
    func returns(_ text: String) {
        #expect(CommandParser.parse(text) == .returnToPrevious)
    }

    @Test func otherGoBacksKeepTheirMeaning() {
        #expect(CommandParser.parse("go back") == nil, "ambiguous: the model decides from context")
        #expect(CommandParser.parse("okay go back") == nil)
        #expect(CommandParser.parse("go back 30 seconds") == .seek(by: -30))
        #expect(CommandParser.parse("go back to the beginning") == .seekTo(0))
        #expect(CommandParser.parse("I want to go back to where I was born") == nil)
    }
}

struct InterpreterReturnTests {
    func context(returnPoint: (Double, Double)?) -> CommandInterpreter.Context {
        .init(title: "Primes", duration: 1340, position: 395, rate: 1, playing: true, transcript: nil,
              returnPoint: returnPoint.map { (time: $0.0, age: $0.1) })
    }

    @Test func returnNeedsAPreviousPosition() {
        let call = [BedrockClient.ToolUse(name: "return_to_previous", input: [:])]
        #expect(CommandInterpreter.commands(from: call, context: context(returnPoint: (842, 90))).commands == [.returnToPrevious])
        let none = CommandInterpreter.commands(from: call, context: context(returnPoint: nil))
        #expect(none.commands.isEmpty)
        #expect(none.notes == ["dropped return_to_previous: no previous position"])
    }

    @Test func theModelIsToldWhereTheyCameFrom() throws {
        let text = { (c: CommandInterpreter.Context) -> String in
            let body = CommandInterpreter.requestBody("okay go back", context: c)
            let messages = body["messages"] as? [[String: Any]]
            return ((messages?[0]["content"] as? [[String: Any]])?[0]["text"] as? String) ?? ""
        }
        #expect(text(context(returnPoint: (842, 130))).contains("Previous position: 14:02 (they jumped away from it 2 minutes ago)."))
        #expect(text(context(returnPoint: nil)).contains("Previous position: none."))
    }
}
