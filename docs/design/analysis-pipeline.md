# The analysis pipeline

What happens to a session *after* it stops, and what is still missing.

The live pass is optimised for latency: it hears twenty milliseconds at a time and cannot
revise what it has already shown. Everything in this document exists because a finished
episode can be looked at all at once, and that is worth a great deal.

## Where it stands

| Piece | State |
|---|---|
| Audio retention | **done** — automatic, verified against real video |
| Speaker separation | **done** — automatic, runs after each session |
| Speaker UI (chips, Raw/Enhanced switch) | **done** |
| Batch re-recognition | **not started** — evidence and API path below |
| `cleanText` in the schema | waiting for it |

## Measurements

Taken on this machine, on real recordings.

| | |
|---|---|
| Recording cost | **274 KB/minute**, ≈ 12 MB for a 45-minute episode |
| Write cost | 0.03 ms per 20 ms buffer, against the 6–8 % of a core the recogniser uses |
| Format | 16 kHz mono AAC (`.m4a`) |
| Diarisation model | 14 MB, downloaded once |
| Diarisation speed | **127× real time** → ≈ 21 s for a 45-minute episode |
| Full analysis, 36 s recording | 27.9 s wall clock, almost all of it the one-time model load |

## Why batch re-recognition is the next thing

The same 113-second recording, transcribed both ways.

**Live (streaming), what the library holds today:**

```
Drawing.
The next day.
There was still no ship in sight.
So Dudley told Brooks to avert his gaze.
And he motioned to Stevens.
That the boy Parker had better be killed.
Dudley offered a prayer.
He told the boy his time had come.
And he killed him with a penknife, stabbing him in the jugular vein.
Brooks emerged from his conscientious objection to share in the gruesome bounty.
For four days.
The three of them fed on the body and blood of the cabin boy.
```

**Batch (whole file):**

```
Drawn. The next day there was still no ship in sight, so Dudley told Brooks to avert his
gaze, and he motioned to Stevens that the boy Parker had better be killed. Dudley offered a
prayer. He told the boy his time had come, and he killed him with a penknife, stabbing him
in the jugular vein. Brooks emerged from his conscientious subjection to share in the
gruesome bounty. For four days, the three of them fed on the body and blood of the cabin
boy. True story.
```

| | Live | Batch |
|---|---|---|
| Punctuation | almost none | **complete** — commas, full stops, sentence boundaries |
| Sentence casing | none | correct |
| Segmentation | fragments, one per line | coherent paragraphs |
| Accuracy | `Drawing.` | **`Drawn.`** |
| One regression | `objection` | `subjection` |
| Completeness | dropped the closing line | kept `True story.` |

The punctuation alone is the argument. Everything laid on top — translation, notes, word
lookup — works on sentences, and the live pass never produces any. This is also the honest
answer to the original complaint that the captions read badly and mis-hear things: the
streaming model is doing what it can with no context, and a second pass with the whole file
in hand fixes most of it.

Batch is not perfect — `subjection` is wrong where the stream was right — which is exactly
why the raw text is kept rather than replaced.

## How to build it

The CLI's `transcribe` prints one block of text with no timing, which cannot be mapped back
onto individual lines. The API that can:

```swift
ParaformerManager.transcribeWithTimestamps(audioURL: URL) throws -> [TimestampedSegment]
```

The shape of the work is then the one already used for speakers, in `SessionAnalyzer`:
segments carry times, each cue takes whichever segment overlaps it most, and the result is
written to `cues.cleanText` rather than over `cues.text`.

Two things to decide when doing it:

* **Which model.** Paraformer is the one with a timestamped file API. Whether it reads
  English as well as the Parakeet model the live pass uses needs measuring, not assuming.
* **Which pass wins.** `cleanText` is shown by default and the raw text stays one toggle
  away, so a bad batch result is visible rather than destructive.

## Traps already paid for

Each of these cost real time. None of them are guessable.

**FluidAudio reads audio through `ExtAudioFile`, which does not open an `.m4a`.**
The recording has to be rewritten as WAV first. `afconvert` fails on an `.m4a` for the same
reason; `AVAudioFile` reads it fine, which is why the conversion is done with `AVAudioFile`.

**Reading past the end of a file throws, and the error is not always `eofErr`.**
`AVAudioFile.read(into:)` signals the end of a stream by throwing rather than by returning
empty. Standalone it threw `eofErr (-39)`; inside the app the same read threw
`_GenericObjCError 0`. A catch that accepted only `eofErr` treated a completed read as a
failure and aborted the entire analysis with every frame already converted. Accept both.

**A WAV's header is only written when the file is released.**
Returning from the conversion while the `AVAudioFile` is still alive leaves a file that
reads as zero seconds long. Release it explicitly before using the result.

**A file still being recorded cannot be opened.**
`close()` must actually release the `AVAudioFile`, and the app flushes on quit — a recorder
torn down on dealloc never gets that chance, and a 260 KB file with no header is unreadable.

**Diarisation output is keyed `speakerId` / `startTimeSeconds` / `endTimeSeconds`.**
Not `speaker` / `start` / `end`. The first version read all three as `None`.

**FluidAudio numbers speakers from zero.** The chip says S1 where the data says `0`.

## Debugging notes

When something in this pipeline fails, the useful move was to log *inside* the function, not
around it. Logging that a conversion failed narrowed nothing; logging each call inside it
showed the failure fell between "output created" and the first write, where only one of the
two possible calls could have thrown. Several rounds were spent re-reading code before that.
