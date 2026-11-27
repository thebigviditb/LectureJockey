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

### Lowering the video while you dictate

On the built-in speakers the mic hears the video, and Wispr transcribes the lecturer instead of you. So when Wispr starts a recording (it inserts an empty row the moment you press the key), LectureJockey lowers the playing video in Chrome's front tab to 10% if it is louder, and restores it when the first of these happens:

- no app is using a microphone any more (Wispr stopped recording),
- Wispr finalizes the row,
- the mic never started within 2 s (a cancelled recording; Wispr leaves those rows unfinalized forever),
- a 10-minute safety cap,
- LectureJockey exits (Ctrl-C or kill).

Headphones, AirPods and other outputs are left alone. If you change the volume yourself mid-recording, your setting wins. `--no-duck` turns it off.

### 2. Gate

A dictation is treated as a command only when all three are true:

1. The player has a video open, playing or paused (v1 asks Chrome's front tab; later macOS Now Playing via `mediaremote-adapter`).
2. The whole utterance matches the command grammar, not just a phrase inside a longer sentence.
3. Wispr's target app is the player app.

This keeps "go back 30 seconds" in a message you're dictating to another app from rewinding a lecture playing in the background.

### 3. Command parser (v1)

Fixed phrases only, no LLM:

- Speed: "2x", "speed up", "slow down", "normal speed"
- Seek: "go back 30 seconds", "skip ahead a minute"
- Jump: "go to the beginning", "restart", "go to 5 minutes", "jump to 2:30", "go to the middle", "skip to 75 percent", "jump to three quarters of the way in", "go to the end"
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
.build/debug/lecturejockey audio            # output device, built-in speakers?, mic in use?
swift test
```

In v1 the gate checks for a playing video by asking Chrome's front tab directly. The log prints the focused element after each command, which shows where Wispr's paste landed.

## Later

- Spoken jumps to a topic ("go back to where he talks about X"), using a timestamped transcript: page captions first, local Whisper as a fallback.
- Learning features on the same transcript (summaries, quizzes), in the spirit of the earlier Polaris project.
