import Foundation

/// Chrome's tabs, addressed by window and tab id, for work that is not about the
/// front tab (fetching a transcript from whichever tab is playing).
public enum ChromeTabs {
    public struct Tab: Sendable, Equatable {
        public let window: String
        public let id: String
        public let url: String
    }

    public static func all() throws -> [Tab] {
        let script = """
            tell application id "\(ChromeDriver.bundleID)"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & ((id of w) as text) & (character id 9) & ((id of t) as text) & (character id 9) & (URL of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        return try AppleScript.run(script).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            return parts.count == 3 ? Tab(window: parts[0], id: parts[1], url: parts[2]) : nil
        }
    }

    /// Runs `js` in one tab and returns its result. Chrome's ids exceed AppleScript's
    /// integer range, so they are matched as text. The script is passed as an argument,
    /// never spliced into AppleScript source.
    public static func run(_ js: String, in tab: Tab) throws -> String {
        let script = """
            on run argv
                tell application id "\(ChromeDriver.bundleID)"
                    repeat with w in windows
                        if ((id of w) as text) is (item 1 of argv) then
                            repeat with t in tabs of w
                                if ((id of t) as text) is (item 2 of argv) then return execute t javascript (item 3 of argv)
                            end repeat
                        end if
                    end repeat
                    return "__lj_no_tab__"
                end tell
            end run
            """
        let out = try AppleScript.run(script, arguments: [tab.window, tab.id, js])
        if out == "__lj_no_tab__" { throw ChromeTabsError.tabGone }
        return out
    }
}

public enum ChromeTabsError: Error, CustomStringConvertible {
    case tabGone
    public var description: String { "the Chrome tab is gone" }
}
