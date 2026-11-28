import Foundation
import LectureJockeyCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    usage:
      lecturejockey watch [--dry-run] [--verbose] [--no-duck] [--no-llm] [--no-transcripts] [--dip-level PERCENT]
                                        act on Wispr Flow dictations while a video plays;
                                        lowers the video (default 10%) while Wispr records on speakers
      lecturejockey parse <text>        show what a phrase parses to
      lecturejockey interpret [--transcript KEY] <text>
                                        what the model would do with a phrase (does not touch the player)
      lecturejockey do <text>           apply a phrase to Chrome's front tab now
      lecturejockey state               show the front tab's video state
      lecturejockey audio               show the output device and whether a mic is in use
      lecturejockey tap-test [PERCENT] [SECONDS]
                                        lower all of Chrome's audio (default 10%, 4 s) to hear a level
      lecturejockey transcript fetch    save the transcript of the YouTube video playing (or in front)
      lecturejockey transcript list     list saved transcripts
      lecturejockey transcript show KEY print a saved transcript with timestamps
    """

/// "--dip-level 25" -> 0.25. Percent of the signal level, so 10 = 20 dB quieter.
func dipLevel(_ args: [String]) -> Double {
    guard let i = args.firstIndex(of: "--dip-level"), i + 1 < args.count else { return Ducker.Config().level }
    guard let p = Double(args[i + 1]), (1...100).contains(p) else { fail("--dip-level takes a percent from 1 to 100") }
    return p / 100
}

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    print("\(f.string(from: Date()))  \(s)")
}

func describe(_ v: ChromeDriver.VideoState?) -> String {
    guard let v else { return "no video" }
    return String(format: "%@ rate=%gx t=%.1fs/%.0fs focus=%@",
                  v.playing ? "playing" : "paused", v.rate, v.time, v.duration, v.activeElement)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("lecturejockey: \(s)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else { print(usage); exit(2) }
args.removeFirst()
let driver = ChromeDriver()
let router = PlayerRouter(chrome: driver)

switch sub {
case "parse":
    let text = args.joined(separator: " ")
    print(CommandParser.parse(text)?.summary ?? "not a command")

case "state":
    do {
        if let t = try router.resolve() { print("[\(t.driver.name)] \(describe(t.video))") } else { print("no video") }
    } catch { fail("\(error)") }

case "interpret":
    // What the model would do with a phrase, without touching the player.
    // --transcript KEY uses a saved transcript (position 0, paused); otherwise the video in front.
    var words = args
    var context: CommandInterpreter.Context?
    if let i = words.firstIndex(of: "--transcript"), i + 1 < words.count {
        guard let t = TranscriptStore().load(words[i + 1]) else { fail("no transcript \(words[i + 1])") }
        context = .init(title: t.title, duration: t.duration, position: 0, rate: 1, playing: true, transcript: t)
        words.removeSubrange(i...(i + 1))
    }
    let text = words.joined(separator: " ")
    do {
        if context == nil {
            guard let target = try router.resolve() else { fail("no video; pass --transcript KEY") }
            context = CommandInterpreter.context(for: target)
        }
        let interpreter = try CommandInterpreter.fromEnvironment()
        let r = try interpreter.interpret(text, context: context!)
        print("calls: \(r.calls.joined(separator: ", "))")
        print("-> \(r.commands.isEmpty ? "nothing" : r.commands.map(\.summary).joined(separator: ", "))\(r.notes.isEmpty ? "" : "  (\(r.notes.joined(separator: "; ")))")")
        print("\(r.latencyMs) ms, tokens in \(r.usage.inputTokens) (cache read \(r.usage.cacheReadTokens), write \(r.usage.cacheWriteTokens)), out \(r.usage.outputTokens), model \(interpreter.model)")
    } catch { fail("\(error)") }

case "audio":
    let mics = DispatchQueue(label: "probe")
    let m = MicMonitor(queue: mics) { _ in }
    mics.sync { m.start() }
    print("output: \(AudioDevices.outputName()) builtInSpeakers=\(AudioDevices.outputIsBuiltInSpeakers()) micInUse=\(m.anyRunning)")

case "transcript":
    let store = TranscriptStore()
    func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    switch args.first {
    case "fetch":
        do {
            let tabs = try ChromeTabs.all().filter { YouTubeTranscript.videoID(from: $0.url) != nil }
            let playing = try tabs.first { try ChromeTabs.run(TranscriptAgent.isPlayingJS, in: $0) == "playing" }
            guard let tab = playing ?? tabs.first else { fail("no YouTube video open in Chrome") }
            let started = Date()
            let t = try YouTubeTranscript().fetch(from: tab)
            try store.save(t)
            print("\(t.key) \"\(t.title)\": \(t.segments.count) lines, \(t.wordCount) words, \(clock(t.duration)) long, in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            print(store.url(for: t.key).path)
        } catch { fail("\(error)") }
    case "list":
        for t in store.all().sorted(by: { $0.updatedAt > $1.updatedAt }) {
            print("\(t.key)  \(t.source.rawValue)  \(t.segments.count) lines  \(clock(t.duration))  \(t.title)")
        }
    case "show":
        guard args.count > 1, let t = store.load(args[1]) else { fail("no transcript \(args.dropFirst().first ?? "")") }
        print("\(t.title) (\(t.source.rawValue), \(clock(t.duration)))")
        for s in t.segments { print("[\(clock(s.start))] \(s.text)") }
    default:
        print(usage); exit(2)
    }

case "tap-test":
    // Lowers all of Chrome's audio for a few seconds, as a dictation over an embedded player would.
    let percent = args.first.flatMap(Double.init) ?? Ducker.Config().level * 100
    let seconds = args.dropFirst().first.flatMap(Double.init) ?? 4
    guard (1...100).contains(percent) else { fail("percent must be 1 to 100") }
    let tap = ChromeAudioTap()
    do {
        try tap.start(gain: percent / 100)
        print("Chrome audio at \(Int(percent))% (\(String(format: "%.0f", 20 * log10(percent / 100))) dB) for \(seconds)s on \(AudioDevices.outputName())")
        Thread.sleep(forTimeInterval: seconds)
        tap.stop()
        print("restored")
    } catch { tap.stop(); fail("\(error)") }

case "do":
    let text = args.joined(separator: " ")
    guard let c = CommandParser.parse(text) else { fail("not a command: \(text)") }
    do {
        guard let t = try router.resolve() else { fail("no video") }
        guard t.driver.supports(c) else { fail("\(c.summary) is not possible for this embedded player") }
        print("[\(t.driver.name)] \(c.summary) -> \(describe(try t.driver.apply(c)))")
    } catch { fail("\(error)") }

case "watch":
    let dryRun = args.contains("--dry-run")
    let noDuck = args.contains("--no-duck")
    do {
        let dbPath = ProcessInfo.processInfo.environment["LJ_WISPR_DB"] ?? WisprHistory.defaultPath
        let watcher = try Watcher(history: try WisprHistory(path: dbPath))
        if args.contains("--verbose") { watcher.onWrite = { log("write event: \($0)") } }

        // Lower the video while Wispr records over the built-in speakers.
        var dipConfig = Ducker.Config()
        dipConfig.level = dipLevel(args)
        let ducker = Ducker(
            volume: ChromeVolume(driver: driver, nowPlaying: router.nowPlaying, log: { log($0) }),
            speakersActive: { AudioDevices.outputIsBuiltInSpeakers() },
            config: dipConfig,
            log: { log($0) }
        )
        let micQueue = DispatchQueue(label: "lecturejockey.mic")
        let mic = MicMonitor(queue: micQueue) { running in ducker.micChanged(running: running) }
        if !noDuck && !dryRun {
            micQueue.sync { mic.start() }
            watcher.onRecordingStart = { ducker.recordingStarted($0) }
            watcher.onRecordingEnd = { ducker.recordingFinished($0) }
        }
        // Never leave a video at 10% on exit.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { ducker.restoreNow(); exit(0) }
            source.resume()
            return source
        }
        _ = signals

        // Claude (Haiku on Bedrock) handles phrasings no grammar rule covers. Without AWS credentials, grammar only.
        let interpreter: CommandInterpreter? = {
            guard !args.contains("--no-llm") else { return nil }
            do { return try CommandInterpreter.fromEnvironment() } catch { log("model off: \(error)"); return nil }
        }()

        // Save each YouTube video's transcript once, as soon as it starts playing.
        let transcripts = TranscriptAgent(log: { log($0) })
        let nowPlayingStream = router.nowPlaying.map { NowPlayingStream(executable: $0.executable) }
        if !args.contains("--no-transcripts") {
            nowPlayingStream?.start { transcripts.nowPlayingChanged($0) }
        }

        log("watching \(watcher.history.path)\(dryRun ? " (dry run)" : "")\(noDuck || dryRun ? "" : ", volume dip to \(Int(dipConfig.level * 100))% on built-in speakers (output now: \(AudioDevices.outputName()))"), model \(interpreter.map { $0.model } ?? "off"), Now Playing fallback \(router.nowPlaying == nil ? "off (brew install media-control)" : "on"), YouTube transcripts \(nowPlayingStream == nil || args.contains("--no-transcripts") ? "off" : "on")")
        watcher.run { d in
            let heard = "\"\(d.text.prefix(80))\" app=\(d.app) url=\(d.url)"
            func execute(_ command: Command, on target: (driver: PlayerDriver, video: ChromeDriver.VideoState)?, via: String) throws {
                let player = target.map { " [\($0.driver.name)]" } ?? ""
                switch Gate.check(command, video: target?.video, supported: target?.driver.supports(command) ?? true) {
                case .skip(let why):
                    log("skip: \(why)\(player)  \(heard)")
                case .ask:
                    break // check() never asks
                case .run:
                    guard let target else { return }
                    if dryRun {
                        log("would run \(command.summary) (\(via))\(player)  \(describe(target.video))")
                    } else {
                        log("\(command.summary) (\(via))\(player) -> \(describe(try target.driver.apply(command)))  \(heard)")
                    }
                }
            }
            do {
                switch Gate.precheck(d) {
                case .skip(let why):
                    // Only show the text for things that looked like commands; the rest is private dictation.
                    log(why == "not a command" ? "skip: not a command (\(d.app))" : "skip: \(why)  \(heard)")
                case .run(let command):
                    try execute(command, on: try router.resolve(), via: "grammar")
                case .ask:
                    guard let interpreter else { log("skip: not a command (\(d.app))"); return }
                    // Only a dictation into Chrome while it has a video is sent to the model.
                    guard let target = try router.resolve() else { log("skip: not a command, no video (\(d.app))"); return }
                    let context = CommandInterpreter.context(for: target)
                    let r = try interpreter.interpret(d.text, context: context)
                    let via = "model \(r.latencyMs) ms\(context.transcript == nil ? "" : ", transcript")"
                    guard !r.commands.isEmpty else {
                        // The model said it is not a command: log why, not the private dictation.
                        log("skip: \(r.notes.joined(separator: "; ")) (\(via))")
                        return
                    }
                    if !r.notes.isEmpty { log("note: \(r.notes.joined(separator: "; "))") }
                    var current: (driver: PlayerDriver, video: ChromeDriver.VideoState)? = target
                    for command in r.commands {
                        try execute(command, on: current, via: via)
                        // The next command checks against the state after this one.
                        current = try router.resolve()
                    }
                }
            } catch {
                log("error: \(error)")
            }
        }
    } catch { fail("\(error)") }

default:
    print(usage); exit(2)
}
