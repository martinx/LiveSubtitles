# The Study Window — design

Status: **proposal, not implemented**. Everything here is written to be argued with.

The overlay answers "what is being said right now". This is the other half: what to do
with it afterwards, for someone using the app to learn English.

---

## 1. What the app already has

| Piece | Where it lives now |
|---|---|
| System audio capture | `SystemAudioCapture` (ScreenCaptureKit, 16 kHz mono) |
| Streaming recognition | `StreamingTranscriber` (Parakeet EOU / Unified / Nemotron) |
| Cue segmentation + timing | audio-clock bounds, sentence-boundary cuts |
| Session transcript | `TranscriptStore`, in memory only, `.srt` / `.txt` export |
| Overlay | `CaptionPanel` / `CaptionView` |

The gap: nothing survives a restart, and nothing is analysed. That is what this design
adds.

## 2. What is available on-device

Verified against the installed SDK and the FluidAudio checkout, not assumed:

| Need | Framework / model | Requirement |
|---|---|---|
| Corrections, rewriting, cloze, summaries, grading | **FoundationModels** — `SystemLanguageModel`, `LanguageModelSession`, guided generation | macOS 26+ |
| Translation | **Translation** framework (`TranslationSession`) | macOS 15+ |
| Tokenising, lemmas, part of speech, named entities | **NaturalLanguage** — `NLTagger`, `NLTokenizer` | macOS 10.14+ |
| Definitions, offline | **DictionaryServices** — `DCSCopyTextDefinition` | always |
| Speech | FluidAudio TTS: Kokoro, KokoroAne, Chatterbox, StyleTTS2, LuxTts, NeuTts, PocketTTS, Supertonic3; `AVSpeechSynthesizer` as fallback | — |
| Who said what | FluidAudio Diarizer (LS-EEND, Sortformer) | — |
| Search | SQLite **FTS5** (system SQLite) | always |
| Slow playback without pitch change | `AVAudioUnitTimePitch` | always |

## 3. Feasibility, honestly

| # | Your requirement | Verdict | Notes |
|---|---|---|---|
| 1 | Full history, export anything | **Easy** | SQLite + FTS5. Export SRT/VTT/TXT/Markdown/CSV/JSON, per session or a range. |
| 2 | Clean-up, denoise, auto-correct | **Partly — see below** | Text-level: yes. *Audio*-level denoise is impossible unless we keep the audio, because we do not record it today. |
| 3 | Local translation + split view | **Yes** | Translation framework is on-device; the language pack is a one-time system download. Fallback: the local LLM. |
| 4 | Select a word, take notes, save it | **Yes** | Needs a tokenised reader rather than plain `Text`, so a selection maps to a word. Dictionary comes from the system. |
| 5 | Sentence / frequency / syntax statistics, study guidance | **Mostly — syntax is the weak spot** | Frequency and POS are solid. Real dependency parsing is not available on-device; see §6. |
| 6 | Replay, with a nice voice | **Two separate things** | Replaying *the original actor* needs the audio kept. Replaying *a synthetic voice* works today. |
| 7 | Look a word up, find its sentences everywhere | **Easy** | FTS5 + `DCSCopyTextDefinition`; a concordance (keyword-in-context) view is a query away. |

## 4. Where your list is underspecified

These are the parts worth deciding before any code is written.

### 4.1 "Denoise" means two different things

- **Audio denoise** — remove music, hiss, rumble *before* recognition. Impossible
  retroactively: we transcribe the live stream and throw the samples away. It becomes
  possible only if we start keeping audio (§5.2).
- **Text clean-up** — remove what the recogniser hallucinated. Very possible, and it is
  most of the value:
  - drop cues with no real words (already partly done);
  - collapse repetition loops the model falls into ("you know you know you know");
  - drop cues recognised over pure music or applause;
  - fix casing and spacing; normalise numbers, times, money (FluidAudio already ships ITN);
  - re-split cues so a line does not start mid-clause.

Keep two columns always: `raw_text` (what the model said) and `clean_text` (what we
produced). Never overwrite the raw one — it is the only ground truth we have.

### 4.2 Auto-correction can make things worse

An LLM asked to "fix" a transcript will happily invent names and improve grammar that was
deliberately colloquial. Rules for the correcting pass:

- give it the neighbouring cues for context, ask only for corrections of clear
  mis-hearings, and require the answer as structured output (FoundationModels guided
  generation) listing `(index, replacement)` pairs;
- reject any edit that changes more than a small share of the sentence, or that replaces a
  word with one of a very different frequency;
- store the original, show the diff, and let the line be reverted individually;
- never run the correcting pass over the live overlay — it is for the study window only.

### 4.3 "Syntax statistics" is the one thing that does not have a good local answer

`NLTagger` gives part-of-speech tags and lemmas, which supports a lot: tense detection,
clause boundaries at punctuation and conjunctions, question vs statement, modal use,
passive-ish constructions. It does **not** give a dependency tree. Options:

1. heuristics on POS (cheap, no model, ~80% of the useful signals);
2. bundle a small CoreML dependency parser (extra model to source, convert and licence);
3. ask the local LLM to describe the structure of a sentence (works, slow, less reliable
   en masse, fine on demand for one sentence).

Recommendation: start with (1), use (3) on demand in the inspector, and treat (2) as a
later upgrade.

## 5. The two decisions that shape everything

### 5.1 Minimum macOS

FoundationModels needs **macOS 26**. The overlay runs on **macOS 14** today.

- **Option A** — keep the overlay at 14, and gate the whole study window behind
  `@available(macOS 26, *)`. The app still runs for everyone; the study features appear
  only on 26+. Costs some `#available` noise.
- **Option B** — raise the whole app to macOS 26. Simplest code, smallest audience.
- **Option C** — no Apple LLM; use MLX with a small instruct model. Works on older macOS,
  but adds a multi-GB model download and our own prompt plumbing.

Recommendation: **A**, and revisit once the study window is real.

### 5.2 Do we keep the audio?

This single choice decides replay, real denoise, and shadowing.

- **Keep it**: we already hold the PCM buffers. Write them as AAC per session
  (~0.5 MB/minute mono at 64 kbps — an hour is ~28 MB). Then a cue can be replayed
  exactly, slowed down, and re-recognised with a bigger model later.
- **Do not keep it**: replay is limited to a synthetic voice, and denoise stays text-only.

If we keep it, the honest design is: **opt-in, per session, clearly labelled**, with a
retention policy (e.g. "delete audio after 30 days") and a one-click "forget this
session". Recording someone else's media to disk is a real thing to be explicit about,
even locally, and a privacy-first app should default to off.

## 6. Proposed architecture

### 6.1 Storage

SQLite, one file in Application Support, with FTS5 for search. Sketch:

```sql
sessions(id, started_at, ended_at, source_app, source_title, model_id,
         keep_audio, audio_path, audio_start_ms, language)
cues(id, session_id, start_ms, end_ms, raw_text, clean_text, corrected_text,
     translated_text, speaker, flags)
words(id, lemma, surface, pos, cefr, total_count)
cue_words(cue_id, word_id, position)
notes(id, kind, cue_id, char_start, char_end, text, tags, created_at)
vocab(word_id, status, first_seen, last_seen, srs_interval, srs_ease, srs_due)
analyses(session_id, stage, model, version, payload_json, completed_at)
cues_fts USING fts5(raw_text, clean_text, corrected_text,
                    content='cues', content_rowid='id')
```

Each analysis stage is cached and versioned, so re-running a better model later is a
migration rather than a rewrite.

### 6.2 Analysis pipeline (per session, on demand, resumable)

```
raw cues
  → clean          deterministic text clean-up                   (no model)
  → correct        LLM mis-hearing fixes, diff-reviewed           (FoundationModels)
  → translate      sentence-level, cached per language pair       (Translation framework)
  → analyse        tokens, lemmas, POS, CEFR, frequency           (NLTagger + word list)
  → stats          coverage, new words, WPM, sentence types       (pure arithmetic)
```

Every stage writes its own row in `analyses`, so progress is visible and a stage can be
re-run alone.

### 6.3 Window

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ [Session ▾]  [🔍 Search everything]   [▶︎ original|voice]  [speed 1.0×]  [Export]│
├────────────────┬──────────────────────────────────────────────────────────────┤
│ Sessions       │ 00:01:23  She apologised twice, although it was not her fault.│
│ Notebook       │           她道了两次歉,虽然这并不是她的错。                    │
│ Favourites     │           she · apologised · twice · although · fault          │
│ Vocabulary     │ 00:01:27  He was in no mood to be polite.                     │
│ Statistics     │           …                                                   │
├────────────────┴──────────────────────────────────────────────────────────────┤
│ Inspector — word or line: dictionary, all its sentences, notes, add to study    │
└───────────────────────────────────────────────────────────────────────────────┘
```

- The reader is a **tokenised** list, not a `Text`: each word is its own view, which is
  what makes "select a word and act on it" possible.
- Clicking a word opens the inspector: definition, pronunciation, every other sentence it
  appears in, "mark as known/unknown", "add to notebook".
- Dragging across words makes a phrase note; the selection is stored as
  `(cue_id, char_start, char_end)` so it survives re-analysis.

## 7. Beyond your list

Ordered by value to a learner, not by effort:

1. **Shadowing / read-aloud** — play a line, record the microphone, transcribe it with the
   engine we already have, and show a per-word diff against the original. This is the
   single highest-value addition for speaking, and it uses only what is already here.
   (Needs microphone permission — a new prompt, unrelated to Screen Recording.)
2. **Coverage tracking** — mark words as known; then report "you understand 94% of this
   episode" and track it across sessions. Turns a pile of transcripts into progress.
3. **Spaced repetition** — SM-2 over the vocabulary table, with a daily queue in the
   window. No new dependency.
4. **Anki export** — CSV or AnkiConnect, so the review can live where the learner already
   works. Cloze cards generated from the sentence a word came from.
5. **Dictation practice** — hear the line, type it, get a word-level score.
6. **Blur / peek** — hide the translation and the transcript until you ask for it.
7. **Word-level karaoke** during replay, highlighting each word as it is spoken.
   (FluidAudio's EOU path exposes token timestamps; forced alignment would cover the
   other models.)
8. **Speaker diarization** — who said what, for dialogue-heavy shows. Already in
   FluidAudio.
9. **Study notes export** — Markdown/HTML of a session with the notes, the unknown words
   and the sentences that contained them.
10. **Saved searches** — "every line with a modal + past perfect", straight from FTS +
    POS tags.

## 8. Suggested order

| Phase | Content | Why first |
|---|---|---|
| 0 | Persistence, sessions, history list, export, search | Nothing else is possible without it |
| 1 | Bilingual reader, tokenised words, dictionary, notes, favourites | The daily-use loop |
| 2 | Text clean-up, then LLM correction with diff review | Makes the archive trustworthy |
| 3 | Replay: kept audio, slow-down, TTS re-speak, word highlight | The "listen again" payoff |
| 4 | Statistics, coverage, SRS, Anki, dictation, shadowing | The actual studying |

## 9. Open questions

1. **macOS 26 requirement** — acceptable for the study window, or must it work on 14?
2. **Keep the audio** — opt-in recording of the captured media, or synthetic voice only?
3. **Priority** — is the goal comprehension (reading/listening), vocabulary, or speaking?
   The answer reorders phases 2–4.
4. **Translation target** — Chinese, and is a per-sentence or a per-paragraph translation
   wanted? Per-paragraph reads better but cannot be aligned line by line.
5. **How much history** — is this for one episode at a time, or the whole back catalogue
   with cross-session statistics?
