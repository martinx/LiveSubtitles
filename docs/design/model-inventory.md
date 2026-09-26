# Model inventory for the study window

The live path needs one kind of model: a streaming recogniser. Everything *after* the
session is a different set of problems, and the ASR model contributes almost nothing to
them. This is the full inventory of what each post-processing task actually needs, what is
available locally today, and where the honest gaps are.

Marked **[verified]** where I checked the installed SDK or the FluidAudio checkout, and
**[estimate]** where the number is a calculation rather than a measurement.

---

## 1. The tasks, and what each one really needs

| Task | Needs | Best local option | Why not something simpler |
|---|---|---|---|
| Drop hallucinated cues over music | Audio event classification | **SoundAnalysis** `SNClassifySoundRequest` [verified] | Text heuristics guess; the classifier knows the segment was music |
| Cut cue boundaries, drop silence | Voice activity detection | **FluidAudio VAD** (Fsmn) [verified] | Already in the dependency |
| Numbers, dates, money | Inverse text normalisation | **FluidAudio `TextNormalizer`** [verified] | Already in the dependency |
| Fix obvious mis-hearings | LLM with context | **Tier 2 LLM** (§3) | A 3B model rewrites too freely; see §4 |
| Punctuation and casing for EOU output | LLM or a punctuation model | Tier 1 for speed, Tier 2 for quality | EOU emits none at all; the default model already punctuates |
| Spoken → written normalisation | LLM | Tier 2 | Filler removal and false starts are judgement calls |
| Who said what | Speaker diarisation | **FluidAudio `OfflineSortformerDiarizer`** [verified] | Runs after the session; see §5 |
| Word-level timing (karaoke, precise replay) | Token timestamps or forced alignment | **FluidAudio `TokenTimestamps`** [verified] — EOU exposes them; other models still need alignment | Cue-level timing is not enough to highlight a word |
| English → Chinese translation | MT or a bilingual LLM | **Translation framework** [verified] for the fast path; **Tier 2 LLM** for nuance | Line-by-line MT reads worse than a paragraph pass |
| Word lookup | Dictionary | **`DCSCopyTextDefinition`** [verified] | Free, offline, no model |
| Grammar in learner writing | Deterministic checker first | **`NSSpellChecker.checkGrammarOfString:grammarDetails:`** [verified] | Catches the mechanical errors for free, and grounds the LLM |
| Explain *why* a sentence is wrong | LLM | Tier 2 | This is teaching, not proofreading |
| Grade a summary | LLM with rubric | Tier 2 | Judgement — the weakest thing a 3B model does |
| Generate cloze / exercises | LLM, structured | Tier 1 is fine | Constrained and short |
| Tokens, lemmas, POS, entities | Tagger | **`NLTagger`** [verified] | Deterministic, instant, free |
| Frequency and CEFR band | Word list + counts | Bundled list + SQLite | No model needed; licensing is the issue (§7) |
| Readability (Flesch etc.) | Arithmetic | None | Pure calculation |
| Semantic search, "similar sentences" | Sentence embeddings | **`NLContextualEmbedding` / `NLEmbedding`** [verified] | Free and on-device; no vector DB model needed |
| Topic grouping, dedup across episodes | Embeddings + clustering | Same as above | — |
| Text search | Index | **SQLite FTS5** [verified] | — |
| Read a line aloud | TTS | **FluidAudio TTS** (Kokoro, KokoroAne, Chatterbox, StyleTTS2, LuxTts, NeuTts, PocketTTS, Supertonic3) [verified], or Apple premium voices | — |
| Speaking practice | Recognition of the learner + comparison | **Existing ASR** + word diff | True pronunciation scoring is a gap; see §6 |
| Conversation partner | LLM + TTS + ASR | Tier 2 + FluidAudio TTS | Fully local |
| Dependency / syntax analysis | Parser | **Gap** — see §6 | `NLTagger` gives POS, not a tree |

## 2. Four tiers

**Tier 0 — no model at all.** System grammar checker, ITN, VAD, readability, FTS5,
dictionary, embeddings. Instant, deterministic, free, and they should always run first:
a deterministic pass cannot hallucinate, and it grounds whatever the LLM does next.

**Tier 1 — Apple's system models.**
`FoundationModels` `SystemLanguageModel` [verified], `Translation` [verified],
`NLTagger` / `NLEmbedding` / `NLContextualEmbedding` [verified], `SoundAnalysis` [verified].
No download, no setup beyond enabling Apple Intelligence. Roughly 3B parameters
**[estimate]** — Apple does not publish the figure.

**Tier 2 — a real local LLM, via MLX.** For the tasks where Tier 1 is genuinely mediocre
(§4). MLX Swift is the Apple-supported route for this; Apple ran a WWDC25 session on
running local LLMs with MLX
([session 298](https://developer.apple.com/videos/play/wwdc2025/298/)).

**Tier 3 — task-specific models.** Diarisation, TTS, alignment. Already covered by
FluidAudio, which we ship anyway.

## 3. Which local LLM

Memory is the binding constraint: 24 GB unified, and roughly 9 GB goes to macOS, the app
and caches **[estimate]**, leaving about 15 GB.

| Option | Weights (4-bit) | Fits with ASR loaded | Notes |
|---|---|---|---|
| Apple `SystemLanguageModel` | ~2 GB | yes | Zero setup; weakest reasoning |
| Qwen3-8B | ~5 GB | yes | Fast; noticeably behind 14B on nuance |
| **Qwen3-14B** | **~8.5 GB** | **yes** | Bilingual EN/ZH, strong instruction following — **recommended default** |
| Gemma 3 12B | ~7 GB | yes | Comparable; weaker Chinese |
| Qwen3-30B-A3B (MoE, 3B active) | ~17 GB | no | Best quality; needs the ASR released, and is still tight |
| Llama 3.3 8B | ~5 GB | yes | English-strong, Chinese-weak |

**Recommendation: Qwen3-14B-Instruct, 4-bit, served through MLX Swift.** It is the largest
model that coexists comfortably with the recogniser, it is genuinely bilingual (which
matters because translation goes to Chinese), and MoE-class speed is not needed for
after-the-fact work.

**Qwen3-30B-A3B as an opt-in "maximum quality" tier** for anyone willing to accept that
the recogniser is unloaded while studying. The memory maths:

```
方案 A  Apple ~3B   + ASR      3.1 GB   余 11.9 GB   ✓ 舒适
方案 B  Qwen3-14B   + ASR      9.6 GB   余  5.4 GB   ✓ 可行
方案 C  Qwen3-30B   (卸 ASR)  17.5 GB   余 -2.5 GB   ⚠ 必须错峰
```

The reason C is viable at all is the key structural fact of this design:

> **Live captioning and study never happen at the same moment.** So the ASR model and the
> LLM do not have to coexist. Release one to load the other — which also means the app's
> steady-state memory is the *max* of the two, not the sum.

## 4. Where the 3B system model is not good enough

This is the honest answer to "is the model enough". For these tasks, shipping only Tier 1
would be the mediocre feature:

| Task | Why 3B disappoints |
|---|---|
| Grading a summary against a rubric | Needs judgement and consistency; small models flatter everything |
| Explaining a grammar error | Tends to restate the correction, not the rule |
| Correcting ASR mis-hearings | Over-eager: invents names, formalises slang, "improves" lines nobody asked to improve |
| English → Chinese at paragraph level | Fluency and idiom are where small models fall down hardest |
| Long-context consistency across an episode | Loses track of who said what and which names were established |
| Free-form conversation practice | Repeats itself, drifts out of character |

Everything else — cloze, glosses, tone checks, short rewrites, classification — Tier 1
does well, and it does it instantly and silently.

**So the design is not "pick one".** It is: always run Tier 0 first, use Tier 1 by default,
and escalate to Tier 2 for the tasks above, with the escalation visible in the UI so it is
never a silent quality difference.

## 5. Where each model runs

```
during the episode (must never stutter)
    ASR  +  VAD  +  ITN                     → cues, timing, audio (kept)
    no LLM, no diarisation, no analysis

after the episode (background, cancellable)
    SoundAnalysis   drop music-only cues
    Diarisation     OfflineSortformerDiarizer over the kept audio
    Alignment       token timestamps where available
    Tier 0          grammar check, ITN, tokens, lemmas, POS, frequency, readability
    Embeddings      sentence vectors for semantic search and topic grouping
    Tier 1          quick clean-up, cloze, glosses
    Tier 2          correction, translation, grading, conversation      ← the expensive pass
```

Nothing in the second block can touch subtitle latency: it runs when nothing is being
captioned, and if the user starts listening again the analysis pauses.

## 6. Two gaps with no good local answer

**1. Dependency / syntactic parsing.** `NLTagger` gives part of speech and lemmas, which
supports tense, clause boundaries, question vs statement, modals and passive patterns. It
does not give a tree. Options, in order of cost:

1. heuristics over POS tags — no model, covers most of what a learner needs to *see*;
2. ask the Tier 2 LLM to parse one sentence on demand, in the inspector, where latency does
   not matter;
3. convert a small dependency parser (spaCy-class) to CoreML — a real project, worth it
   only if (1) and (2) prove insufficient.

Recommendation: ship (1) and (2), and do not pretend it is a parser.

**2. Pronunciation scoring.** Word-level *accuracy* comes free: our own recogniser
transcribes the learner and we diff against the reference, which catches wrong words and
missing words. What it does **not** measure is pronunciation quality of a correctly
recognised word — that needs a dedicated goodness-of-pronunciation model, and there is no
mature on-device option today. Shadowing should therefore present itself as
*"did you say the right words"*, not as a pronunciation score. Overstating this would be
exactly the mediocre feature to avoid.

## 7. Licensing, because it decides what can ship

- **FluidAudio** — Apache 2.0, already shipped, and it covers ASR, VAD, ITN, diarisation
  and TTS. No new licensing surface.
- **Apple frameworks** — no licence question, but they require macOS 26+ and, for some
  features, a one-time system download (translation language packs, premium voices).
- **MLX and the weights** — MLX itself is MIT. The model licence is per-model: the Qwen
  family is Apache 2.0, Gemma has its own terms. Weights are **downloaded by the user, not
  redistributed**, which keeps the obligation on the model, not on us — the same pattern
  already used for the ASR models.
- **CEFR / frequency word list** — the one genuinely unresolved item. A bundled list is a
  redistribution, so it must be permissively licensed. This needs a decision before phase 5.

## 8. What I would build

1. **Always**: Tier 0 passes. They are instant, deterministic, and they make the archive
   trustworthy.
2. **Default**: Tier 1 for everything it does well.
3. **Ship a Tier 2 option**: Qwen3-14B via MLX, downloaded on first use with an explicit
   prompt showing the size. It is what makes correction, translation, grading and
   conversation actually good.
4. **Escalate explicitly**: the UI says which tier produced a result, and any line can be
   re-run at the higher tier.
5. **Measure before trusting**: for correction and translation, run both tiers on the same
   episode and compare with the raw transcript before deciding which is the default.
