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
