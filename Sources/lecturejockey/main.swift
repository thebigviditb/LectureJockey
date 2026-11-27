import Foundation
import LectureJockeyCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    usage:
      lecturejockey watch [--dry-run] [--verbose]
                                        act on Wispr Flow dictations while a video plays
      lecturejockey parse <text>        show what a phrase parses to
      lecturejockey do <text>           apply a phrase to Chrome's front tab now
      lecturejockey state               show the front tab's video state
    """

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

switch sub {
case "parse":
    let text = args.joined(separator: " ")
    print(CommandParser.parse(text)?.summary ?? "not a command")

case "state":
    do { print(describe(try driver.state())) } catch { fail("\(error)") }

case "do":
    let text = args.joined(separator: " ")
    guard let c = CommandParser.parse(text) else { fail("not a command: \(text)") }
    do { print("\(c.summary) -> \(describe(try driver.apply(c)))") } catch { fail("\(error)") }

case "watch":
    let dryRun = args.contains("--dry-run")
    do {
        let dbPath = ProcessInfo.processInfo.environment["LJ_WISPR_DB"] ?? WisprHistory.defaultPath
        let watcher = try Watcher(history: try WisprHistory(path: dbPath))
        if args.contains("--verbose") { watcher.onWrite = { log("write event: \($0)") } }
        log("watching \(watcher.history.path)\(dryRun ? " (dry run)" : "")")
        watcher.run { d in
            let heard = "\"\(d.text.prefix(80))\" app=\(d.app) url=\(d.url)"
            switch Gate.precheck(d) {
            case .skip(let why):
                // Only show the text for things that looked like commands; the rest is private dictation.
                log(why == "not a command" ? "skip: not a command (\(d.app))" : "skip: \(why)  \(heard)")
            case .run(let command):
                do {
                    let before = try driver.state()
                    switch Gate.check(command, video: before) {
                    case .skip(let why):
                        log("skip: \(why)  \(heard)")
                    case .run:
                        if dryRun {
                            log("would run \(command.summary)  \(describe(before))")
                        } else {
                            log("\(command.summary) -> \(describe(try driver.apply(command)))  \(heard)")
                        }
                    }
                } catch {
                    log("error: \(error)")
                }
            }
        }
    } catch { fail("\(error)") }

default:
    print(usage); exit(2)
}
