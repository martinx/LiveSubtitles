# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-27

Everything below is about what happens *around* the captions: keeping them, reading them,
looking words up in them, and understanding who said what.

### Added

- **The Library window** (menu bar → Library…, ⌘L). Every session is kept with its transcript
  and can be browsed, searched across, renamed, filed into folders, exported and annotated.
  Three columns: a folder tree of any depth, the sessions inside it, and the transcript.
- **Persistent history** in `~/Library/Application Support/Live Subtitles/history.sqlite` —
  SQLite with FTS5, so search runs over everything ever recorded.
- **⌘K**, one field over sessions, lines, words, notes, folders and commands. The same field
  finds a line and runs “Translate This Session”.
- **Word lookup.** Double-click any word for the system dictionary's entry — pronunciation,
  part of speech, senses — its meaning in Chinese, every other line it appears in, and a
  second opinion from Wiktionary. All of it inside the card; nothing opens a browser.
- **Paragraph translation** into Simplified Chinese, on demand and on-device. The first run
  asks macOS for the language pairs and the toolbar says so.
- **Notes** in Markdown, with the source line quoted in automatically and that line's words
  one tap away.
- **Audio retention.** Each session keeps the sound it was transcribed from — 16 kHz mono AAC,
  about 12 MB for a 45-minute episode, against the 6–8 % of a core the recogniser already uses.
- **Speaker separation**, run after each session and shown as a coloured, numbered chip on
  every line, with a switch between the enhanced reading and the raw transcript.
- **`LiveSubtitlesKit`**, a local package holding the storage layer, deliberately free of
  AppKit so it can be tested without launching the app. 12 tests, run in CI.

### Changed

- The whole interface follows the macOS 26/27 design language: Liquid Glass where the system
  provides it and materials below that, a sectioned status menu, a Library menu with keys,
  and settings rebuilt as glass cards.
- Caption typography: SF Pro semibold, tracking scaled to the size, leading at 1.18×, and a
  wide soft shadow in place of the hard one, which read as an outline rather than as type.
- Study icons redrawn as one shape each at one weight, so the labels start on one line.
- The sidebar is a real folder tree: any depth, the disclosure triangle on the trailing edge
  as the Finder has it, and a New Folder row that is always there. Folders and sessions drag.

### Fixed

- The library did not follow a recording. Cues were always written as they were finished, but
  the window read the archive once, when it opened, and never again.
- The sidebar width was never applied at all: a toolbar modifier sitting between the list and
  its width setting stopped it, so the sidebar stayed at its 192 pt default however large the
  window was — growing the window only widened the reading column.
- Double-clicking a word re-translated the whole episode. The scope and the request id were
  separate values, and a word lookup could leave the scope saying “paragraphs”.

### Planned

- **Batch re-recognition**: re-transcribe a finished session from its retained audio, which
  brings punctuation, sentence casing and better accuracy. The evidence, the API to use and
  the traps already paid for are written up in
  [`docs/design/analysis-pipeline.md`](docs/design/analysis-pipeline.md).
- Offline transcription of local files, pre-transcribed with a batch model and exported as a
  perfectly timed `.srt` with zero live latency.

## [0.1.6] - 2026-09-26

### Fixed

- The overlay window could intermittently size itself to almost the whole screen, leaving
  an invisible panel across the display that swallowed clicks. The cause was the SwiftUI
  content asking for unbounded height (`.frame(maxHeight: .infinity)`), which lets AppKit
  fit the window to the screen. Measured over eight consecutive launches with a long
  passage playing, the overlay is now a stable 193 pt where it previously reached 1065 pt.

### Changed

- Releases are described from `CHANGELOG.md` instead of GitHub's generated commit list, and
  the workflow refuses to publish a tag that has no changelog section.

## [0.1.5] - 2026-09-26

### Fixed

- **Max lines works again.** 0.1.4 removed a layout constraint in order to fix a bad height
  measurement, which instead left the overlay pinned to about two lines: raising Max lines
  grew nothing, the extra lines were clipped. The constraint is back, and the bad
  measurement is now bounded by what the settings can actually require — the bar holds at
  most `lineLimit` lines, so the ceiling is exact.
- Verified by counting rendered lines from screenshots for Max lines = 2/3/4/5:
  2, 3, 3, 4 lines respectively, never above the limit, with the overlay height growing
  94 → 127 → 160 → 196 pt.

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
