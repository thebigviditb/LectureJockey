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

For a player embedded from another domain (SproutVideo, Vimeo), the page's JavaScript can't reach the video, so LectureJockey lowers all of Chrome's audio instead, with a Core Audio process tap (macOS 14.2+): the tap mutes Chrome's own output and plays it back at 10% on the current output. It is used only when Now Playing says Chrome is playing and the tab has no reachable video. Capturing another app's audio needs the System Audio Recording permission (asked of the app that launched LectureJockey). `lecturejockey tap-test 25` plays Chrome at 25% for a few seconds so you can pick a level by ear; `watch --dip-level 25` uses it. Levels are a percent of the signal, so 10% is 20 dB quieter, which sounds close to silent under speech.

Headphones, AirPods and other outputs are left alone. If you change the volume yourself mid-recording, your setting wins. `--no-duck` turns it off.

### 2. Gate

A dictation is treated as a command only when all three are true:

1. The player has a video open, playing or paused (v1 asks Chrome's front tab; later macOS Now Playing via `mediaremote-adapter`).
2. The whole utterance matches the command grammar, or Claude calls a player tool for it (not `no_action`).
3. Wispr's target app is the player app.

This keeps "go back 30 seconds" in a message you're dictating to another app from rewinding a lecture playing in the background.

### 3. Understanding the command

Two stages:

1. **Grammar first.** Known phrasings match instantly and work offline. A phrase must match from first word to last, so a command phrase inside a longer sentence never triggers.
2. **Claude for everything else.** When no rule matches, the dictation went into Chrome and the front tab has a video, it goes to Claude Haiku on Amazon Bedrock with the video's transcript (when there is one) and a set of tools: `set_rate`, `change_rate`, `seek_by`, `seek_to`, `seek_to_line`, `pause`, `play` and `no_action`. The model answers only with tool calls, so "skip the intro", "go back to where he explains Dirichlet's theorem" or "skip to the part about pi approximations and play it at 1.5x" work, and a new feature is a new tool. For content it names a transcript line, and the line's start time comes from the transcript file, never from the model. Every call is validated; out-of-range ones are dropped.

The instructions and transcript come before a cache point, so later commands on the same video read them from the prompt cache (Haiku 4.5 caches prompts over 4096 tokens, Haiku 5.5 over 512). On a one-hour lecture a command costs about $0.014 uncached and $0.002 cached on Haiku 4.5, a tenth of that on Haiku 5.5. Only that one dictation's text and the transcript are sent.

Credentials come from an `aws` CLI profile; requests are signed with SigV4 in Swift (no SDK).

```sh
LJ_AWS_PROFILE=intension LJ_AWS_REGION=us-west-2 LJ_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0   # the defaults
.build/debug/lecturejockey interpret --transcript youtube:EK32jo7i5LQ "skip the intro"   # what it would do
LJ_LLM_EVAL=1 swift test --filter InterpreterEval                                         # the live phrase list
```

**Going back to where you were.** Every jump (to a topic, a time, a percentage, or by an amount) records the position it left, like a browser's back button. "Go back to where I was", "take me back", "back to where I left off" or "undo that" return there instantly; a bare "okay, go back" or "okay I'm good with this" goes to the model, which sees the previous position and how long ago you left it. Returning uses that point up, so saying it again steps further back. With no earlier jump, a bare "go back" rewinds about 10 seconds. One history per video.

Grammar phrasings include:

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
| Video embedded from another domain (SproutVideo, Vimeo, Wistia) | macOS Now Playing via `media-control` (built) | no | yes | yes |
| Anything else (incl. Firefox) | MediaRemote | usually no | yes | yes |

LectureJockey decides the driver before acting: Chrome's JavaScript when the front tab has a video it can reach (everything works, including speed), else macOS Now Playing when Chrome is what's playing (play, pause and seeking; Chrome does not accept speed changes that way). Now Playing needs `brew install media-control`, which works around Apple's macOS 15.4 restriction through the system Perl; it relies on a private framework, so a macOS update may break it. Media from other apps (Spotify, Music) is never touched.

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

`--no-llm` runs grammar only. In v1 the gate checks for a video by asking Chrome's front tab directly. The log prints the focused element after each command, which shows where Wispr's paste landed.

## Transcripts

Each video gets one transcript file in `~/Library/Application Support/LectureJockey/transcripts/`, in video time (seconds from the start): segments with start, end and text, plus the stretches of the video they cover.

- **YouTube:** when a YouTube video starts playing, LectureJockey reads its transcript from YouTube's own "Show transcript" panel, once per video. It moves the panel off-screen before opening it, closes it after, and puts focus back, so nothing on the page changes (measured: player, side column, recommendations, scroll and focus identical before and after). The direct routes do not work: the JavaScript AppleScript runs cannot see the page's variables, caption downloads come back empty without a token only YouTube's player makes, and the `get_transcript` request answers `FAILED_PRECONDITION`. If YouTube's layout changes, the fetch fails instead of saving a wrong transcript.
- **Everything else:** transcribed on this Mac while you watch. A listen-only Core Audio tap hears Chrome's own output (not the room, the mic or the volume dip), Apple's on-device speech recognizer (SpeechAnalyzer, macOS 26; 38x real time on a test clip) turns it into sentences, and Now Playing's position, speed and play/pause reports turn each sentence's time into video time. It runs only while Chrome plays a video with no YouTube transcript, and stops on pause. Rewatching replaces what was heard instead of duplicating it; skipped parts stay as gaps in `covered`. Stored as `nowplaying:<title>|<length>`. `lecturejockey listen 60` prints a minute of it; `watch --no-live` turns it off.

```sh
.build/debug/lecturejockey transcript fetch        # the YouTube video playing, or the first one open
.build/debug/lecturejockey transcript list
.build/debug/lecturejockey transcript show youtube:oZDzd8jpGWc
```

## Later

- Spoken jumps to a topic ("go back to where he talks about X"), using a timestamped transcript: page captions first, local Whisper as a fallback.
- Learning features on the same transcript (summaries, quizzes), in the spirit of the earlier Polaris project.
