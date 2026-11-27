import Foundation
import LectureJockeyCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    usage:
      lecturejockey watch [--dry-run] [--verbose] [--no-duck] [--no-jev] [--dip-level PERCENT]
                                        act on Wispr Flow dictations while a video plays;
                                        lowers the video (default 10%) while Wispr records on speakers
      lecturejockey parse <text>        show what a phrase parses to
      lecturejockey classify <text>     ask Jev what a phrase means (needs the Keychain key)
      lecturejockey do <text>           apply a phrase to Chrome's front tab now
      lecturejockey state               show the front tab's video state
      lecturejockey audio               show the output device and whether a mic is in use
      lecturejockey tap-test [PERCENT] [SECONDS]
                                        lower all of Chrome's audio (default 10%, 4 s) to hear a level
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

case "classify":
    let text = args.joined(separator: " ")
    guard let jev = JevClassifier.fromKeychain() else { fail("no Jev key in the Keychain (service LectureJockey, account typesafe)") }
    do {
        let a = try jev.classify(text)
        let c = jev.command(for: a, text: text)
        print("\(a.intent.rawValue) \(String(format: "%.2f", a.confidence)) position=\(a.position.rawValue) -> \(c?.summary ?? "not acting")")
    } catch { fail("\(error)") }

case "audio":
    let mics = DispatchQueue(label: "probe")
    let m = MicMonitor(queue: mics) { _ in }
    mics.sync { m.start() }
    print("output: \(AudioDevices.outputName()) builtInSpeakers=\(AudioDevices.outputIsBuiltInSpeakers()) micInUse=\(m.anyRunning)")

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

        // Jev handles phrasings no grammar rule covers. Without a key, grammar only.
        let jev = args.contains("--no-jev") ? nil : JevClassifier.fromKeychain()

        log("watching \(watcher.history.path)\(dryRun ? " (dry run)" : "")\(noDuck || dryRun ? "" : ", volume dip to \(Int(dipConfig.level * 100))% on built-in speakers (output now: \(AudioDevices.outputName()))"), Jev \(jev == nil ? "off" : "on"), Now Playing fallback \(router.nowPlaying == nil ? "off (brew install media-control)" : "on")")
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
                    guard let jev else { log("skip: not a command (\(d.app))"); return }
                    // Only a dictation into Chrome while it has a video is sent to Jev.
                    guard let target = try router.resolve() else { log("skip: not a command, no video (\(d.app))"); return }
                    let started = Date()
                    let answer = try jev.classify(d.text)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    let verdict = "jev \(answer.intent.rawValue) \(String(format: "%.2f", answer.confidence)) in \(ms) ms"
                    guard let command = jev.command(for: answer, text: d.text) else {
                        log("skip: \(verdict), not acting")
                        return
                    }
                    try execute(command, on: target, via: verdict)
                }
            } catch {
                log("error: \(error)")
            }
        }
    } catch { fail("\(error)") }

default:
    print(usage); exit(2)
}
