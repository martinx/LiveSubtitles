# Contributing

Thanks for taking a look. This is a small, focused app — the best contributions are bug
reports with a reproduction and narrowly scoped fixes.

## Getting set up

```bash
git clone https://github.com/<owner>/LiveSubtitles.git
cd LiveSubtitles

make build      # release build -> build/LiveSubtitles.app
make run        # build and launch
make install    # build and copy to /Applications
```

You need macOS 14+, Apple Silicon, and the Xcode command line tools. The first run
downloads a speech model and compiles it for the Neural Engine, which takes 40–90 s;
after that, loads take about 2 s.

`make debug` builds faster but runs slower.

## Trying things without a video

The app transcribes whatever the system is playing, so any audio source works:

```bash
afplay -v 5 some-clip.wav      # system audio, captured like any other app
```

Useful switches:

```bash
LIVESUBTITLES_DEBUG=1 make run                     # trace partials, cues, state, hot keys
LIVESUBTITLES_DUMP_SRT=/tmp/out.srt make run       # mirror the transcript to disk
LIVESUBTITLES_OPEN_SETTINGS=1 make run             # open settings on launch
```

## House rules

- **Everything stays on-device.** The only network access allowed is the one-time
  model download. A change that phones home, adds analytics, or requires an account
  will not be merged.
- **No new dependencies** without a good reason and a licence that is compatible with
  MIT and with FluidAudio's Apache 2.0.
- **Measure latency claims.** If you change the engine, the chunking, or the cue logic,
  say what changed and how you measured it.
- Match the surrounding style. Comments should explain *why*, not restate the code.

## Layout

```
Sources/LiveSubtitles/    the whole app, one file per concern (see README)
Resources/                Info.plist and the generated icon
scripts/                  build, run, install, icon generation
docs/                     the landing page (GitHub Pages)
```

## Pull requests

1. Keep the diff focused; unrelated cleanups go in their own PR.
2. Run `make build` and make sure it is warning-free.
3. Describe what you changed and how you verified it. Screenshots help for UI changes.
4. Update `CHANGELOG.md` under `[Unreleased]` if the change is user-visible.

## Reporting bugs

Use the bug report template. The most useful reports include:

- macOS version and hardware,
- which model is selected (Settings → Engine),
- what you expected versus what appeared on screen,
- relevant `LIVESUBTITLES_DEBUG=1` output if the bug is about recognition or timing.
