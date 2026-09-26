# The Study Window — design


> What happens to a session after it stops — audio retention, speaker
> separation, and the case for re-recognising with the whole file — is in
> [`analysis-pipeline.md`](analysis-pipeline.md).

Status: **proposal, not implemented**. Revision 2, after the first round of decisions.

The overlay answers "what is being said right now". This is the other half: what to do
with it afterwards, for someone using the app to learn English.

---

## 1. Decisions taken

| Decision | Answer | Consequence |
|---|---|---|
| Minimum macOS | **26+** (27 fine) | `FoundationModels`, `Translation`, `_Translation_SwiftUI` usable directly. No `@available` gymnastics, no feature tiers. Deployment target rises from 14 to 26. |
| Quality vs reach | **Quality wins** | Where a feature needs an OS-level setup step (Apple Intelligence on, translation language pack, premium voice, model download), the app **detects and guides** rather than degrading. No "if unavailable, fall back to something worse" paths. |
| Keep the audio? | **Yes, one episode's worth** | Enables exact replay, real denoise, and shadowing. Retention is bounded (§5). |
| Translation | Chinese, **by paragraph**, optional | A paragraph block under the paragraph, not a line under each line. Word-level is handled by selection instead. |
| Working unit | **One episode at a time** | Sessions are the unit; collections/topics are created freely on top. |
| Skills | **All four** — listen, speak, read, write | Writing includes conversation and summary with graded correction (§9.4). |
| Retention | **Nothing is ever deleted automatically** — not text, not audio | Capacity was the worry; measurement says an episode is ~7 MB, so it was not a real constraint (§5). Manual deletion only. |
| Session naming | Free-form title, editable | Default is auto-generated from the source and date; season/episode/series are optional fields, and collections group sessions any way you like. |
| Code layout | **A library module, in this repo, extractable later** | The overlay must not depend on study code (§13). |

## 2. What the app already has

| Piece | Where |
|---|---|
| System audio capture | `SystemAudioCapture` — ScreenCaptureKit, 16 kHz mono, 320-frame buffers |
| Streaming recognition | `StreamingTranscriber` — Parakeet EOU / Unified / Nemotron |
| Cue segmentation + audio-clock timing | sentence-boundary cuts, audio-energy pauses |
| Session transcript | `TranscriptStore`, memory only, `.srt` / `.txt` |
| Overlay | `CaptionPanel` / `CaptionView` |

The gap: nothing survives a restart, nothing is analysed, and the audio is discarded.

## 3. What is available on-device

Verified against the installed SDK and the FluidAudio checkout:

| Need | Framework / model | Requirement |
|---|---|---|
| Correction, rewriting, summary grading, conversation, cloze | **FoundationModels** — `SystemLanguageModel`, `LanguageModelSession`, guided generation | macOS 26+ |
| Translation | **Translation** — `TranslationSession` | macOS 15+ |
| Tokens, lemmas, part of speech, entities | **NaturalLanguage** — `NLTagger`, `NLTokenizer` | always |
| Offline definitions | **DictionaryServices** — `DCSCopyTextDefinition` | always |
| Speech synthesis | FluidAudio TTS (Kokoro, KokoroAne, Chatterbox, StyleTTS2, LuxTts, NeuTts, PocketTTS, Supertonic3); `AVSpeechSynthesizer` + premium voices | — |
| Who said what | FluidAudio Diarizer (LS-EEND, Sortformer) | — |
| Search | SQLite **FTS5** | always |
| Slow playback, pitch preserved | `AVAudioUnitTimePitch` | always |

## 4. Feasibility

| # | Requirement | Verdict |
|---|---|---|
| 1 | Full history, export anything | **Easy** — SQLite + FTS5; export SRT/VTT/TXT/Markdown/CSV/JSON |
| 2 | Clean-up, denoise, auto-correct | **Yes, now that audio is kept** — text clean-up is deterministic; audio denoise becomes possible offline; LLM correction is diff-reviewed |
| 3 | Local translation, split view | **Yes** — on-device, per paragraph |
| 4 | Select a word, note it, save it | **Yes** — needs a tokenised reader, not a plain `Text` |
| 5 | Sentence / frequency / syntax statistics | **Frequency and POS yes; dependency parsing no** — see §7 |
| 6 | Replay, with a good voice | **Both** — the original from kept audio, a synthetic voice from TTS |
| 7 | Look up a word, find its sentences | **Yes** — FTS5 + dictionary + concordance |
| 8 | Speak | **Yes** — shadowing and a fully local voice conversation |
| 9 | Write | **Yes** — summary and conversation exercises with graded, structured feedback |

## 5. Keeping the audio — measured

The question was whether retention would hurt live subtitles. Measured on this M3 with the
same 320-frame / 20 ms buffers the live path uses, encoding to AAC:

| | |
|---|---|
| Encoding 59 s of audio | **0.083 s** |
| Share of one core, in real time | **0.14 %** |
| Per 20 ms buffer | **0.028 ms** (budget 20 ms) |
| Size | **159 KB/minute ≈ 9.5 MB/hour** |
| App's own cost while recognising | 6–8 % CPU, 140 MB |

So retention is about **2 % of what recognition already costs**. It cannot delay subtitles —
provided the writer never applies backpressure:

- the audio stream is **teed**, not chained: the recognition consumer stays the only reader
  on the ordered path, and the writer is fed from a **bounded queue that drops audio when
  full**. If the disk stalls, we lose recording, never latency;
- encoding happens off the capture path entirely, never on the stream's delivery queue;
- implementation note: a 16 kHz mono AAC encoder **rejects a 64 kbps request**
  (`AudioConverterSetProperty` fails); let the encoder choose, which lands near 22 kbps.

### Retention policy — and why the capacity worry was unfounded

Measured: **159 KB/minute**, so a 45-minute episode is **7.0 MB**.

| Usage | Per month | Per year | 10 years |
|---|---|---|---|
| 1 episode/day | 0.2 GB | 2.6 GB | 25.7 GB |
| 2 episodes/day | 0.4 GB | 5.1 GB | 51.3 GB |
| 3 episodes/day | 0.6 GB | 7.7 GB | 77.0 GB |

Keeping every episode's audio for a decade costs less than a handful of films. So:

- **Nothing is deleted automatically** — not text, not audio. Deletion is always a
  deliberate action, per session or from a storage panel that shows what each session
  costs.
- If the disk gets tight, the app **warns and offers** to prune; it never prunes for you.
- The one thing that is bounded is memory, not disk — see the model broker in the
  [model stack](model-inventory.md).

## 6. Storage

SQLite in Application Support, with FTS5. Sketch:

```sql
sessions(id, started_at, ended_at, source_app, source_title, model_id,
         keep_audio, audio_path, audio_start_ms, language, duration_ms)
collections(id, name, kind, created_at)          -- episode, topic, anything
collection_sessions(collection_id, session_id)

cues(id, session_id, paragraph_id, start_ms, end_ms,
     raw_text, clean_text, corrected_text, speaker, flags)
paragraphs(id, session_id, start_ms, end_ms, translated_text, translation_lang)

words(id, lemma, surface, pos, cefr, total_count)
cue_words(cue_id, word_id, position)

notes(id, kind, cue_id, char_start, char_end, text, tags, created_at)
vocab(word_id, status, first_seen, last_seen, srs_interval, srs_ease, srs_due)
writing(id, session_id, kind, prompt, body, feedback_json, score, created_at)

analyses(session_id, stage, model, version, payload_json, completed_at)
cues_fts USING fts5(raw_text, clean_text, corrected_text,
                    content='cues', content_rowid='id')
```

`raw_text` is never overwritten: it is the only ground truth. Every derived column is
recomputable, and every analysis stage is versioned so a better model later is a
migration rather than a rewrite.

### Measured capacity

A synthetic database at one year of daily watching — **260 episodes, 130,000 cues,
1,300,000 word links** — was built and queried:

| | |
|---|---|
| Database size | **91 MB** |
| Build time | 4.3 s |
| Full-text search across all history | **0.57 ms** |
| Every occurrence of a word (concordance) | 0.21 ms |
| One session's cues | 0.21 ms |
| Word-frequency aggregation | 0.91 ms |

SQLite is nowhere near being the constraint; ten years extrapolates to about 900 MB with
the same latencies. **One query did stand out**: computing a session's share of
above-level vocabulary took **153 ms**, because it filtered on a non-indexed column across
1.3 M rows — an order of magnitude worse at ten years' scale. Two consequences for the
schema:

1. index `words(cefr)` and `cue_words(word_id, cue_id)`;
2. do not recompute per-session statistics on the fly — materialise them into an
   `analyses` row when the session is processed, which the pipeline already does.

## 7. Analysis pipeline

```
raw cues
  → clean       deterministic: drop hallucinations, collapse repeats, drop
                music-only cues, normalise numbers/dates/money, re-split clauses
  → correct     LLM mis-hearing fixes as (index, replacement) pairs, diff-reviewed
  → denoise     optional, only where audio is kept: re-run a cleaner model over the
                stored audio and re-recognise the weak cues
  → paragraph   group cues into paragraphs on long pauses and topic shifts
  → translate   paragraph-level, Chinese, cached per language pair
  → analyse     tokens, lemmas, POS, CEFR band, frequency        (NLTagger + word list)
  → stats       coverage, new words, WPM, sentence types, error profile
```

Correction rules, because an LLM asked to "fix" a transcript will invent names and
formalise deliberate colloquialisms:

- pass neighbouring cues as context and ask only for clear mis-hearings;
- require structured output, and reject edits that change too much of a sentence or swap
  in a word of a very different frequency;
- keep the original, show a diff, allow per-line revert;
- never apply corrections to the live overlay — this is for the study window only.

**Syntax is the honest weak spot.** `NLTagger` gives POS and lemmas, which supports tense,
clause boundaries, question vs statement, modals, passive-ish patterns. It does not give a
dependency tree. Plan: heuristics first, the LLM on demand for a single sentence in the
inspector, and a bundled CoreML parser only if it earns its place.

## 8. Window

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ [Session ▾] [🔍 Search]  [▶︎ original|voice] [0.75×]  [Summarise]  [Export]     │
├────────────────┬──────────────────────────────────────────────────────────────┤
│ Sessions       │ 00:01:23  She apologised twice, although it was not her fault.│
│ Collections    │ ─────────────────────────────────────────────────────────────  │
│ Notebook       │ 她道了两次歉,虽然这并不是她的错。          ← paragraph block     │
│ Favourites     │                                                               │
│ Vocabulary     │ 00:01:27  He was in no mood to be polite.                     │
│ Writing        │ ─────────────────────────────────────────────────────────────  │
│ Statistics     │ 他完全没有心情讲礼貌。                                          │
├────────────────┴──────────────────────────────────────────────────────────────┤
│ Inspector — word or line: definition, its other sentences, notes, add to study  │
└───────────────────────────────────────────────────────────────────────────────┘
```

- The reader is **tokenised**: each word is its own view, which is what makes "select a
  word and act on it" possible. A selection is stored as
  `(cue_id, char_start, char_end)` so it survives re-analysis.
- Replay follows the cue's **audio-clock** bounds, which the pipeline already produces, so
  it is sample-accurate against the kept audio.

## 9. The four skills

### 9.1 Listen
Replay the original at 0.5–1.5× without pitch change; loop a line; word-level highlight
during playback; blur/peek so the transcript is hidden until asked for.

### 9.2 Read
Paragraph-aligned bilingual reader; click any word for a definition; concordance view of
every sentence containing it; mark known/unknown as you go.

### 9.3 Speak
- **Shadowing**: play a cue, record the microphone, transcribe with the engine we already
  ship, and diff against the reference **word by word** — score, and show which words were
  missed or mangled.
- **Voice conversation**: microphone → recognition → local LLM → TTS, entirely on-device.
  Scenarios are grounded in the episode's vocabulary, so practice reuses what was just
  watched.

**Microphone permission, deliberately:**

- **Never asked at launch.** It is requested the first time the learner actually presses
  *Record* or starts a voice session, so the prompt arrives with obvious context.
- **Explained before the system prompt**, in-app: what is recorded, that it stays on this
  Mac, and that the recording is discarded after scoring unless *keep my recording* is on.
- The denial path is a first-class state, not an error: the window shows what is
  unavailable and links to System Settings. Everything else keeps working.
- Shadowing recordings are **ephemeral by default**; keeping one is a per-exercise choice,
  and they live beside the session so they can be deleted with it.
- `NSMicrophoneUsageDescription` says what is actually true, in one sentence.

### 9.4 Write
- **Summary / retell**: after an episode, the user writes a summary. The LLM grades it on
  *content coverage* (did it capture the key beats) and *language* (grammar, word choice,
  naturalness), and returns a model rewrite.
- **Guided conversation**: a written role-play grounded in the episode; the model replies
  in character and corrects as it goes.
- **Structured feedback** via guided generation, so it can be rendered and, more
  importantly, accumulated:

  ```swift
  @Generable struct Feedback {
      var corrections: [Correction]   // original, corrected, reason, category
      var coverage: Double            // 0–1, against the episode's key beats
      var language: Double
      var modelRewrite: String
  }
  ```
- **Error profile**: because every correction carries a category, the app can show what
  *you* repeatedly get wrong — articles, tense, prepositions, collocation — and feed those
  back into the next exercise. This is the part that turns correction into teaching.

## 10. Translation, concretely

- Grouping: a paragraph ends on a long pause or a clear topic shift; each paragraph gets
  one translation, rendered as a block under it. Line-by-line translation is deliberately
  not offered — it reads worse and teaches less.
- Word-level is **selection-driven**: select a word or phrase, get a short Chinese gloss
  plus the sentence it came from.
- Lookup order: system dictionary (`DCSCopyTextDefinition`) → local LLM gloss →
  `TranslationSession`. The system's bilingual dictionary may not cover EN→ZH, so the LLM
  is the realistic primary for glosses; a dedicated dictionary is a possible later addition.
- Translation is optional per session and cached per language pair.

## 11. Order of work

| Phase | Content | Why |
|---|---|---|
| 0 | Persistence, sessions, collections, history list, export, FTS search | Nothing else is possible without it |
| 1 | Audio retention (teed writer, purge policy) | Unlocks replay, denoise, shadowing |
| 2 | Tokenised bilingual reader, dictionary, notes, favourites, paragraph translation | The daily-use loop |
| 3 | Text clean-up, then diff-reviewed LLM correction | Makes the archive trustworthy |
| 4 | Replay: exact, slow, looped, word-highlighted; TTS re-speak | The "listen again" payoff |
| 5 | Statistics, coverage, error profile, SRS, Anki export | Turns the archive into progress |
| 6 | Speaking: shadowing, then voice conversation | Highest-value addition for production |
| 7 | Writing: summary grading, guided conversation | Completes the four skills |

## 12. Code layout — one repo or two?

The instinct is right: the study features must not be able to destabilise the overlay that
already works. But a second repository is not what buys that.

**What actually buys it** is a module boundary:

```
LiveSubtitles/                      this repo
├── Sources/LiveSubtitles/          the app: overlay + study window UI   (AppKit/SwiftUI)
└── Packages/LiveSubtitlesKit/      no UI, no AppKit — everything else
    ├── Storage/                    SQLite, migrations, FTS
    ├── Models/                     sessions, cues, notes, vocab
    ├── Pipeline/                   clean, re-recognise, correct, translate, analyse
    ├── ModelBroker/                load/evict, memory budget
    └── Tests/
```

- The overlay's code path imports only what it already uses; nothing in the study window
  is reachable from it.
- The kit is an ordinary SwiftPM package, so **it already has its own module, its own
  tests, and its own dependency list**.
- Its API can be tested without launching the app, which is the real reason to separate it.

**On the worry that a user with a simple need must download everything.** They do not, and
the numbers are worth writing down:

| | |
|---|---|
| Whole repository, all 60 tracked files | **0.9 MB** |
| `.git` history | 3.2 MB |
| What a user actually downloads | **9.5 MB DMG** |

A user never clones anything — they get a compiled disk image. Model weights are fetched on
first use, so adding the study features does not inflate that DMG. The repository is smaller
than a single screenshot.

**And two apps would be worse, not cleaner.** The decisive reason is TCC: Screen Recording
is granted per bundle identifier. Two apps means two permission prompts, two grants to keep
in step, and a study app that cannot read the live app's sessions without IPC or a shared
container. It also doubles the release pipeline. One app, two windows; the isolation that
matters comes from the module boundary above.

**Why not a second repository yet.** A separate repo adds a clone, a second CI setup, and
version choreography for every change that touches both sides — for a single developer,
that is friction on every commit in exchange for isolation the module boundary already
provides. It also front-loads a decision we cannot make well yet: the API will not settle
until phases 1–3 exist.

**And it costs nothing to defer**, because the package is already a package. Extracting it
later is: create the repo, move `Packages/LiveSubtitlesKit`, replace `.package(path:)` with
`.package(url:from:)`. **No API change, no code change.**

Extract when one of these becomes true:

1. a second consumer appears — an iOS app, a command-line batch transcriber, anything;
2. the kit's release cadence genuinely diverges from the app's;
3. outside contributors want to work on the kit without the app.

Until then, the boundary is the deliverable; the repository is ceremony.

## 13. Still open

1. **CEFR / frequency word list** — a bundled list is a redistribution, so it must be
   permissively licensed. This is a licensing decision, not a technical one, and it blocks
   only the statistics phase.
2. **Batch recogniser default** — Parakeet TDT (already shipped, fastest, English-tuned) or
   Whisper large-v3-turbo (more robust across accents and music, adds a runtime)? Worth
   measuring both on one episode before choosing.
3. **Qwen3-30B-A3B as a selectable maximum** — it needs the streaming model unloaded. Is
   that trade acceptable, or should 14B be the ceiling?
4. **Diarisation value** — worth the pass on every episode, or only on request?
