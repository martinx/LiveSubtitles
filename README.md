# LiveSubtitles

Real-time **English** subtitles for anything playing on your Mac, plus a one-click
export of the whole session to `.srt`.

Runs in the menu bar, entirely on-device — no network calls, no accounts, no cloud.

## Requirements

- macOS 14+ (developed and measured on macOS 27, Apple M3)
- Apple Silicon (the speech models run on the Neural Engine)
- Xcode command line tools (`swift`)

## Build & run

```bash
./build.sh          # release build + assembles build/LiveSubtitles.app, signed
./run.sh            # quits any running copy and launches it
```

`./build.sh debug` compiles faster but runs slower — use it while iterating, release
for actually watching something.

## Install into /Applications

```bash
./install.sh        # release build + copy to /Applications/LiveSubtitles.app
```

Then launch it like any other app — Spotlight (`Cmd-Space` → `Live Subtitles`),
Launchpad — or `open -a LiveSubtitles`. Re-run `./install.sh` after a change.

For development, `./build.sh && ./run.sh` runs the bundle from `build/` without
touching /Applications.

The **Screen Recording** grant is tied to the app's signature, so updating in place
keeps the permission; if macOS asks again, re-grant it under *System Settings →
Privacy & Security → Screen Recording*.

## First run

1. **Screen Recording permission** — required to capture system audio. macOS prompts
   on first launch.
2. **The model downloads on first use** (433 MB for the 120M models, 594 MB for the
   0.6B ones) into `~/Library/Application Support/FluidAudio/Models/`.
3. **The first load also compiles the CoreML model**, which is why it can take
   40–90 s. That is a one-off: later launches load in about **2 s**, and the compiled
   model is cached system-wide.

## Using it

Click the captions bubble in the menu bar:

| Item | What it does |
|---|---|
| Restart Engine | Reloads the model and restarts capture. **Your transcript is kept.** |
| Clear Captions | Empties the on-screen text *and* the session transcript |
| Export Transcript… | Saves the session as `.srt` (or `.txt`) |
| Copy Transcript | Puts the whole transcript on the clipboard |
| Settings… | Engine, behaviour and appearance options |
| Quit | Stops capture and exits |

The menu-bar icon switches to a filled bubble while capturing.

The overlay is click-through and never takes focus, so it can sit over a full-screen
video without interrupting playback.

## Models

The engine is a setting, not a hard-coded choice. All are English, on-device, and run
on the Neural Engine.

| Model | Params | First word | Punctuation | Download |
|---|---|---|---|---|
| Parakeet EOU @160 ms | 120M | **0.63 s** | no | 433 MB |
| Parakeet EOU @320 ms | 120M | ~0.7 s | no | 433 MB |
| **Parakeet Unified @320 ms** (default) | 0.6B | 0.86 s | **yes** | 594 MB |
| Parakeet Unified @640 ms | 0.6B | ~1.0 s | yes | 594 MB |
| Nemotron @560 ms | 0.6B | **1.50 s** | yes | ~600 MB |

Measured on an M3 by playing a known sentence ("Quantum mechanics explains the
behaviour of very small particles") and timestamping the app's own output:

| | EOU 120M @160 ms | Unified 0.6B @320 ms | Nemotron 0.6B @560 ms |
|---|---|---|---|
| First word on screen | 0.63 s | 0.86 s | 1.50 s |
| Transcript | "…very small **part of**" | "…small **particles**." | "…small **particles**." |
| Style | run-on lowercase | punctuated, capitalised, numbers normalised | punctuated |

The default is the 0.6B model: ~0.2 s more latency buys correct words plus real
punctuation and capitalisation.

**Why not the 640 ms tier?** It is the same model, not a more accurate one: FluidAudio
describes it as *"same WER as 320 ms at ~2.5x the RTFx"* — it re-encodes far less
often. That is an efficiency tier, so it only helps a machine that is struggling for
compute. On an M3 the 320 ms tier runs comfortably, so 640 ms just adds 0.32 s of
delay for nothing.

**Why not Nemotron?** Measured 0.64 s slower to first word with no accuracy gain on
the test sentence. Worth trying only if a particular show trips up Parakeet.

## Settings

| Setting | Notes |
|---|---|
| **Model** | Which streaming speech model to run. Needs **Apply & Restart Engine**. |
| End of sentence after | How much silence closes a subtitle line. Needs **Apply & Restart Engine**. |
| **New line after silence** | Off / 2 / 3 / 5 / 8 s. After that much quiet, the next sentence starts a **fresh line** instead of being appended to the previous one. |
| **Keep captions on screen** | Stop the overlay fading out during quiet stretches. |
| **Show Dock icon** | Off by default — the app is a menu-bar accessory and never takes activation from the video. Turn on for a Dock icon, a Cmd-Tab entry, a full app menu, and a **LIVE** badge on the Dock tile while capturing. |
| **Drag to reposition** | The overlay is click-through by default. Turn on to grab it and put it where you want; the spot is remembered. **While it is on, the overlay captures the mouse**, so clicks in its area no longer reach the video — turn it off once positioned. |
| Font size / Width / Background / Distance from bottom | Apply immediately |
| Max lines | 1–5. 1 = current sentence only · 2 = previous line above it · 3+ gives the current sentence two lines and keeps more history. |

Once you have dragged the overlay, the saved position wins over *Distance from bottom*
until you press **Reset overlay position**.

### How captions appear and disappear

Worth knowing, because three separate things can clear the screen:

1. **New line (text dropped).** After `New line after silence` of *quiet audio*, the
   running line is discarded so the next sentence starts fresh. The break is applied
   when speech resumes, not during the pause — the last line stays readable while
   nothing is being said.
2. **Fade out.** Unless *Keep captions on screen* is on, the overlay fades out
   (`showsCaption = false`, 0.28 s) 6 s after the fade timer starts — i.e. after
   "new line" delay **plus** 6 s. With *Keep captions on screen* it never fades.
3. **Empty box.** The rounded background disappears whenever there is no text at all.

Pause detection runs on the **audio level**, not on the model going quiet: every one
of these models keeps emitting hallucinated words through silence, which resets a
text-based timer forever. The threshold adapts to the show (audio ~10 dB below the
recent peak, with a slow-decaying peak follower).

## Export format

Export writes SubRip (`.srt`). Cue bounds come from the **audio clock** — the moment a
cue's first words appeared and the moment its last new word arrived — so timings track
playback for every model family:

```
1
00:00:01,760 --> 00:00:04,280
He would rather the meeting is scheduled for tomorrow morning at nine.

2
00:00:07,800 --> 00:00:10,200
I told him to wait outside until the police arrive.
```

> **Timeline caveat:** the clock starts when capture starts, so cue times are relative
> to when you launched (or restarted) the engine. Start captions at the beginning of an
> episode if you want the `.srt` to line up with the file.

## Performance

Measured on an M3 with the default model:

| Metric | Value |
|---|---|
| ScreenCaptureKit buffers | 320 frames = **20 ms**, ~54 buffers/s |
| First word of a stream | **0.86 s** (0.63 s with EOU @160 ms) |
| Per-word lag once running (EOU @160 ms) | **0.1–0.2 s** |
| Model load, warm cache | **~2 s** |
| Model load, first ever use | 40–90 s (download + one-off CoreML compile) |
| Audio work per buffer | O(1) — no resampling, one 1.3 KB copy |

Design choices that keep it cheap:

- **One ordered consumer.** Audio is fed to the model from a single detached task via
  an `AsyncStream`, so buffers cannot be reordered and FluidAudio is only ever touched
  from one place.
- **The capture format is already the model's format.** ScreenCaptureKit is asked for
  16 kHz mono and delivers 16 kHz mono Float32, so nothing is resampled on the hot path.
- **O(1) cue segmentation.** Boundaries are "no new words for 700 ms" or "22 words",
  and line breaks come from audio energy — no per-show VAD to tune.
- **Bounded rendering.** Only a trailing window of transcript is drawn, partials are
  only pushed when the text actually changed, and cues with no actual words (a stray
  `?` from noise) are dropped.
- **The engine is never reset between sentences** — resetting discards encoder context
  and can clip the start of the next line.

## Debugging

```bash
LIVESUBTITLES_DEBUG=1 ./run.sh                   # trace partials, cues, pauses, state
LIVESUBTITLES_DUMP_SRT=/tmp/out.srt ./run.sh     # mirror the transcript to disk
LIVESUBTITLES_OPEN_SETTINGS=1 ./run.sh           # open the settings window on launch
```

Trace tags: `[partial]`, `[utterance]`, `[pause]`, `[newline]`, `[state]`, `[drag]`,
`[status]`, `[cue]`.

## Icon

Original artwork, drawn from scratch by `scripts/make-icon.py` (Pillow): a dark
"screen" carrying a white caption card with two text lines and a speech tail, plus a
coral dot for "live". No third-party icon assets are used.

```bash
python3 scripts/make-icon.py      # writes icon_1024.png + a size-legibility strip
./build.sh                        # bundles Resources/AppIcon.icns
```

## Architecture

```
Sources/LiveSubtitles/
├── App.swift                 entry point (accessory unless the Dock icon is on)
├── AppDelegate.swift         status item, status menu, app main menu, Dock state
├── CaptionController.swift   wires everything; owns export + settings window
├── SystemAudioCapture.swift  ScreenCaptureKit -> AsyncStream<AVAudioPCMBuffer>
├── StreamingTranscriber.swift multi-model streaming ASR + cue segmentation + pauses
├── TranscriptStore.swift     timestamped cues -> .srt / .txt
├── CaptionModel.swift        committed vs in-progress text, fade-out
├── CaptionView.swift         rolling caption, finished and live text on separate lines
├── CaptionPanel.swift        non-activating, click-through, draggable overlay window
├── Settings.swift            UserDefaults-backed settings (+ migration)
└── SettingsWindow.swift      grouped-form settings UI
```

Data flow:

```
ScreenCaptureKit (16 kHz mono Float32, 20 ms buffers)
        │
        ▼
StreamingTranscriber ── selected model (EOU / Unified / Nemotron) on the ANE
        │  partial text            │  cue bounds from the audio clock
        │  audio-level pauses      │
        ▼                          ▼
   CaptionModel              TranscriptStore
        │                          │
        ▼                          ▼
   CaptionPanel              .srt / .txt export
```

## Why not the original Whisper pipeline

This began as a rewrite of an app whose macOS target used SwiftFasterWhisper. That
pipeline buffered a fixed **4.2 s** window (`WINDOW_SIZE_SAMPLES = 67200`) before every
decode, which put a hard ~4–6 s floor under subtitle latency that no model or parameter
change could remove. It also needed a 1.5 GB model and a CTranslate2 framework whose
headers were pruned, so it would not even compile without patching the dependency.

## Known limitations

- **English only.**
- **No punctuation from the EOU models.** The default 0.6B model punctuates and
  capitalises; switch to EOU and you get run-on lowercase with a full stop appended.
- **Cue splitting is silence-based, not punctuation-based**, so a line can occasionally
  break in an odd place (e.g. `"…until the. Police arrive."`).
- **No automatic recovery for the capture stream.** If ScreenCaptureKit stops (display
  change, permission change, monitor unplugged) audio goes dead until you pick
  **Restart Engine**.
- Word errors and occasional hallucination on music-heavy or heavily accented audio.

### Planned

- **Offline transcription of local files.** Point the app at an episode, transcribe it
  ahead of time with a batch model (Parakeet TDT v2 / Ultra) and export a perfectly
  timed `.srt` — zero latency and higher accuracy than any streaming pass, because the
  whole file is available up front. Streaming stays for anything that cannot be
  pre-processed.
- **Punctuation-aware cue splitting** — prefer to break at a sentence end, and fall
  back to the silence rule when the model gives no punctuation.
- **Auto-reconnect the capture stream** so a display change does not need a manual
  restart.
