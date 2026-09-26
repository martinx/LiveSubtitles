# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Offline transcription of local files: pre-transcribe an episode with a batch model
  and export a perfectly timed `.srt`, with zero live latency.
- Two-pass correction: re-decode each finished cue with a batch model and revise the
  committed line behind the live text.
- Automatic recovery when the capture stream stops (display change, permission change).

## [0.1.4] - 2026-09-26

### Fixed

- The overlay could take a bogus height measurement and size itself to almost the whole
  screen, leaving an invisible panel that swallowed clicks. Measurements are now clamped,
  and the layout constraint that allowed the bad reading is gone.

### Changed

- Local builds prefer a **Developer ID** identity when one is available, so a build made
  here shares its code identity — and therefore its Screen Recording grant — with the
  copy people download.

## [0.1.3] - 2026-09-26

### Added

- **A downloaded copy installs itself.** Run from Downloads or straight out of the disk
  image, the app offers to move itself into Applications and restarts from there. This
  fixes the permission prompt that came back on every launch: a quarantined,
  non-notarised app is run by macOS from a fresh random directory each time, so it never
  looks like the same app twice to the Screen Recording grant.

### Fixed

- Locally built apps report the version from the nearest git tag instead of the
  placeholder in `Info.plist`, which had made the in-app update check offer a version
  "newer" than the code actually running.

## [0.1.2] - 2026-09-26

### Changed

- **Engine settings now apply immediately.** Changing the model, the sentence-end delay or
  the new-line-after-silence delay reloads the engine on the spot instead of waiting for
  an *Apply & Restart Engine* click. The button remains as a manual reload.
- Releases now carry a **disk image** as well as the zip: open it and drag the app to
  Applications. The zip is still what the in-app updater downloads.

### Fixed

- `make dist` no longer rebuilds before packaging. It was re-stamping the app without the
  version the release tag supplied, and would have discarded a signature and any stapled
  notarisation ticket.

## [0.1.1] - 2026-09-26

### Changed

- **Drag to reposition is now on by default.** The overlay window also hugs the caption
  bar instead of reserving a tall empty rectangle above it, so an overlay you can drag no
  longer leaves an invisible dead zone that swallows clicks meant for the video.

### Fixed

- The release workflow no longer fails when no signing secrets are configured (a
  step-level `if` cannot read `secrets`, and the zip was never packaged).

## [0.1.0] - 2026-09-26

First public release.

### Added

- Real-time English subtitles for any audio playing on the Mac, captured through
  ScreenCaptureKit and transcribed fully on-device on the Neural Engine.
- Selectable streaming engine: Parakeet EOU 120M (lowest latency), Parakeet Unified
  0.6B (default: punctuated and capitalised), Nemotron 0.6B.
- Overlay that is click-through, never takes focus, and can be dragged anywhere and
  remembered per display.
- Start / pause / stop control, with configurable global shortcuts (Carbon hot keys,
  no Accessibility permission required).
- Pause keeps the model warm for an instant resume; stop releases it.
- Session transcript with `.srt` export, copy to clipboard, and clear.
- Audio-level pause detection, so line breaks follow real silence rather than the
  model hallucinating through it.
- Cue text tidy-up: stranded punctuation dropped, punctuation runs collapsed, sentence
  boundaries preferred when cutting a cue.
- Original artwork icon, with an optional Dock icon and a `LIVE` state badge.
