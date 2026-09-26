# LiveSubtitles

Real-time English subtitles for anything playing on your Mac, plus a one-click
export of the whole session to `.srt`.

Menu-bar app. Fully on-device — nothing leaves the machine.

## Requirements

- macOS 14+ (developed and measured on macOS 27, Apple M3)
- Apple Silicon (the speech model runs on the Neural Engine)
- Xcode command line tools (`swift`)

## Build & run

```bash
./build.sh          # release build + assembles build/LiveSubtitles.app, signed
./run.sh            # quits any running copy and launches it
```

`build.sh debug` builds faster but runs slower — use it while iterating, release
for actually watching something.

## First run

1. **Screen Recording permission** is required to capture system audio. macOS
   prompts on first launch; grant it under System Settings → Privacy & Security.
2. The speech model (~120 MB) downloads once to
   `~/Library/Application Support/FluidAudio/Models/`.
3. **The first launch takes ~30 s** while CoreML compiles the model. After that
   it loads in well under a second. The compile is cached system-wide.

## Using it

Click the captions icon in the menu bar:

| Item | What it does |
|---|---|
| Restart Engine | Reloads the model and restarts capture |
| Clear Captions | Empties the on-screen text and the session transcript |
| Export Transcript… | Saves the session as `.srt` (or `.txt`) |
| Copy Transcript | Puts the transcript on the clipboard |
| Settings… | Engine and appearance options |

The overlay itself is click-through and never takes focus, so it can sit over a
full-screen video without interrupting playback.

## Settings

| Setting | Notes |
|---|---|
| Streaming chunk | 160 ms = lowest latency, 320/1280 ms = more accurate. Needs **Apply & Restart Engine**. |
| End of sentence after | How much silence closes a subtitle line. Needs **Apply & Restart Engine**. |
| Font size / Width / Background / Distance from bottom / Max lines | Apply immediately |

## Export format

Export writes SubRip (`.srt`) using the speech model's own token alignment, so cue
timings match the audio:

```
1
00:00:01,760 --> 00:00:04,280
He would rather the meeting is scheduled for tomorrow morning at nine.

2
00:00:07,800 --> 00:00:10,200
I told him to wait outside until the police arrive.
```

> **Timeline caveat:** the clock starts when capture starts, so cue times are
> relative to when you launched/restarted the app. Start captions at the beginning
> of an episode if you want the `.srt` to line up with the file.

## Performance

Measured on an M3 with a 160 ms chunk, playing known audio and timestamping the
app's own output:

| Metric | Value |
|---|---|
| ScreenCaptureKit buffers | 320 frames = **20 ms**, 54 buffers/s |
| Per-word display lag (warm) | **0.1–0.2 s** |
| First word of a stream | ~0.4–0.6 s (model warm-up) |
| Model load, warm cache | **0.6 s** |
| Model load, first ever launch | ~30 s (one-off CoreML compile) |
| Audio CPU work per buffer | O(1) — no resampling, no per-buffer allocations beyond one 1.3 KB copy |

Design choices that keep it cheap:

- **One ordered consumer.** Audio is fed to the model from a single detached task
  via an `AsyncStream`, so buffers cannot be reordered and FluidAudio is only ever
  touched from one place.
- **No resampling.** ScreenCaptureKit is asked for exactly 16 kHz mono Int16, which
  is what the model wants.
- **O(1) cue segmentation.** Boundaries come from "the model has produced no new
  words for 700 ms", not from an energy VAD that would need tuning per show.
- **Bounded rendering.** Only a trailing window of transcript is ever drawn, and
  partials are only pushed when the text actually changed.
- **The engine is never reset between sentences** — resetting discards encoder
  context and can clip the start of the next line.

## Why not this project's original Whisper pipeline

The old macOS target used SwiftFasterWhisper, which buffered a fixed **4.2 s**
window (`WINDOW_SIZE_SAMPLES = 67200`) before every decode. That put a hard ~4–6 s
floor under subtitle latency that no model or parameter change could remove, and it
needed a 1.5 GB model plus a CTranslate2 framework with pruned headers.

## Architecture

```
Sources/LiveSubtitles/
├── App.swift                 menu-bar entry point (accessory, no Dock icon)
├── AppDelegate.swift         status item + menu
├── CaptionController.swift   wires everything, owns export + settings window
├── SystemAudioCapture.swift  ScreenCaptureKit -> AsyncStream<AVAudioPCMBuffer>
├── StreamingTranscriber.swift Parakeet EOU streaming + cue segmentation
├── TranscriptStore.swift     timestamped cues -> .srt / .txt
├── CaptionModel.swift        committed vs provisional text, fade-out
├── CaptionView.swift         two-line rolling caption (SwiftUI)
├── CaptionPanel.swift        non-activating click-through overlay window
├── Settings.swift            UserDefaults-backed settings
└── SettingsWindow.swift      settings UI
```

Data flow:

```
ScreenCaptureKit (16 kHz mono, 20 ms buffers)
        │
        ▼
StreamingTranscriber ── Parakeet EOU (ANE), never reset
        │  partial text            │  cue boundaries + token timestamps
        ▼                          ▼
   CaptionModel              TranscriptStore
        │                          │
        ▼                          ▼
   CaptionPanel              .srt / .txt export
```

## Debugging

```bash
LIVESUBTITLES_DEBUG=1 ./run.sh                          # trace partials and cues
LIVESUBTITLES_DUMP_SRT=/tmp/out.srt ./run.sh            # mirror the transcript to disk
```

## Known limitations / next steps

- The 120 M streaming model is tuned for latency, not accuracy. Expect the odd
  word error and occasional hallucination on music-heavy or accented audio, and
  it emits no punctuation or capitalisation (the app only capitalises a line and
  adds a full stop).
- **The obvious next step** is a two-tier setup: keep Parakeet EOU for the instant
  on-screen text, and re-decode each finished cue with a stronger model (Parakeet
  TDT v3 / Ultra, or Apple's `SpeechTranscriber`, which returns properly
  punctuated text) to correct the committed line. That buys accuracy without
  adding perceived latency, because it runs behind the live text.
- English only.
