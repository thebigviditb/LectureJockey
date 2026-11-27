# LectureJockey

Voice control for whatever video you're watching on macOS. Say "speed up 2x" or "go back 30 seconds" to Wispr Flow while a video plays, and LectureJockey applies it to the player.

No browser extension and no LLM computer use. LectureJockey reads what Wispr Flow transcribed, decides whether it was a command, and calls the player directly.

## How it works

```
Wispr Flow  --writes-->  ~/Library/Application Support/Wispr Flow/flow.sqlite
                              |  file watch on the WAL, read the newest History row
Menu-bar agent (macOS)
  dictation listener -> gate -> command parser -> player driver -> on-screen confirmation
```

### 1. Dictation listener

Wispr Flow saves every dictation as a row in the `History` table of its local SQLite database. The listener opens it read-only and reads rows newer than the last one it saw, each time Wispr writes.

SQLite can't notify other processes, so the listener uses kqueue vnode watches: one on the WAL and the database file, which fire on every write, and one on the folder, which reattaches them when SQLite deletes or recreates the WAL. FSEvents doesn't work here: it reports a write to a file only once the writer closes it, and Wispr keeps the database open.

Fields used:

| Field | Use |
|---|---|
| `formattedText`, `asrText` | the spoken command |
| `app` | bundle ID of the app Wispr typed into, e.g. `com.google.Chrome` |
| `url` | the tab's domain for browser dictations, e.g. `youtube.com` |
| `timestamp` | ordering and ignoring stale rows |

The schema is undocumented and may change with a Wispr update, so every read of it lives in one module.

### 2. Gate

A dictation is treated as a command only when all three are true:

1. A video is playing (macOS Now Playing via `mediaremote-adapter`, with power assertions as a backup signal).
2. The whole utterance matches the command grammar, not just a phrase inside a longer sentence.
3. Wispr's target app is the player app.

This keeps "go back 30 seconds" in a message you're dictating to another app from rewinding a lecture playing in the background.

### 3. Command parser (v1)

Fixed phrases only, no LLM:

- Speed: "2x", "speed up", "slow down", "normal speed"
- Seek: "go back 30 seconds", "skip ahead a minute"
- Playback: "pause", "play"

### 4. Player drivers

The agent picks a driver for whichever app is playing.

| Player | Driver | Speed | Seek | Play/pause |
|---|---|---|---|---|
| Chrome, Arc | AppleScript `execute javascript` on the playing `<video>` | yes | yes | yes |
| Safari | AppleScript `do JavaScript` | yes | yes | yes |
| QuickTime | AppleScript | yes | yes | yes |
| IINA | mpv control socket | yes | yes | yes |
| VLC | AppleScript | yes | yes | yes |
| Anything else (incl. Firefox) | MediaRemote | usually no | yes | yes |

The browser drivers need "Allow JavaScript from Apple Events" turned on (Chrome: View > Developer; Safari: Develop menu).

## Status

First test: a CLI with the Wispr listener, the command parser, the gate and the Chrome driver. No menu-bar app, Now Playing or other players yet.

```sh
swift build
.build/debug/lecturejockey watch            # act on dictations while a Chrome video plays
.build/debug/lecturejockey watch --dry-run  # log what it would do
.build/debug/lecturejockey parse "go back thirty seconds"
.build/debug/lecturejockey do "2x"          # apply to Chrome's front tab now
swift test
```

In v1 the gate checks for a playing video by asking Chrome's front tab directly. The log prints the focused element after each command, which shows where Wispr's paste landed.

## Later

- Spoken jumps to a topic ("go back to where he talks about X"), using a timestamped transcript: page captions first, local Whisper as a fallback.
- Learning features on the same transcript (summaries, quizzes), in the spirit of the earlier Polaris project.
