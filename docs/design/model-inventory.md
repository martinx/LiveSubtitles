# Model stack for the study window — quality first

Revision 2. The brief changed: **any model that runs on this machine may be installed**,
so the question is no longer "what does the OS already give us" but "what is actually
best, and does it fit in 24 GB of unified memory".

---

## 0. Resolving "best quality" against "best performance"

They only conflict if you demand both at the same instant. They do not have to:

| Phase | Constraint | What runs |
|---|---|---|
| **Live captioning** | Must not stutter. Everything here is already chosen for latency. | Streaming ASR + VAD + ITN, nothing else |
| **After the episode** | Background, cancellable, no deadline. | The entire heavy stack |

So the live path is unchanged, and quality is limited only by what fits in memory *when
nothing is being captioned*. That is the whole licence to be greedy.

## 1. The biggest quality win is not an LLM — it is a second ASR pass

The current design assumes we clean up the streaming transcript's errors with an LLM.
That is backwards. An LLM rewriting mis-heard words is guessing; **re-recognising the
audio with a batch model is measuring.** We keep the audio specifically to make this
possible.

```
during the episode   streaming Parakeet        →  live subtitles (0.6–0.9 s, unchanged)
after the episode    batch model on the same audio →  the transcript we actually keep
```

This is the single highest-value item in the whole plan: it fixes the recognition errors
you complained about at the source, and it also yields word-level timestamps for free in
most batch models, which is what karaoke highlighting and precise replay need.

Candidate batch models, all of which fit:

| Model | Size | Strength | Word timings |
|---|---|---|---|
| **Parakeet TDT v3 / Ultra** (FluidAudio, ANE) | 0.6–1.2 GB | Tops the Open ASR leaderboard for English; already in our dependency | via aligner |
| **Whisper large-v3-turbo** (whisper.cpp / WhisperKit) | ~1.6 GB | Very robust across accents and music; timed | built in |
| **Whisper large-v3** | ~3 GB | Highest Whisper accuracy | built in |
| **Canary-1B / Canary-Qwen-2.5B** (NVIDIA) | 1–2.5 GB | Strong EN accuracy + translation | built in |

Recommendation: **run Parakeet TDT first (free, already shipped, fastest on the ANE) and
Whisper large-v3-turbo as the alternative**, let the user pick per session, and keep the
streaming transcript alongside so the two can be compared.

## 2. The full stack

| Task | Model | Size (4-bit / as noted) | Runtime |
|---|---|---|---|
| Live recognition | Parakeet EOU / Unified (current) | 0.4–1.1 GB | CoreML / ANE |
| **Batch re-recognition** | **Parakeet TDT v3**, or **Whisper large-v3-turbo** | 0.6–1.6 GB | CoreML / whisper.cpp |
| Word-level alignment | wav2vec2 phoneme aligner (WhisperX-style) | ~0.4 GB | CoreML / ONNX |
| Voice activity, ITN | FluidAudio VAD + `TextNormalizer` | tiny | CoreML |
| Music / applause detection | SoundAnalysis, or a CLAP-style classifier | 0 / ~0.2 GB | CoreML |
| Diarisation | FluidAudio `OfflineSortformerDiarizer`; pyannote 3.x if converted | 0.3 / ~0.2 GB | CoreML |
| **Main LLM (default)** | **Qwen3-14B-Instruct** | **~8.5 GB** | MLX |
| **Main LLM (maximum)** | **Qwen3-30B-A3B** (MoE, 3B active) | **~17 GB** | MLX |
| Translation EN→ZH | **Hunyuan-MT** class dedicated MT (Tencent won WMT25 EN-ZH with this family); Qwen3 as fallback | 4–8 GB | MLX |
| Sentence embeddings | Qwen3-Embedding / bge-m3 | 0.3–1.2 GB | MLX |
| Grammar (deterministic) | `NSSpellChecker.checkGrammarOfString` | 0 | system |
| Dictionary | `DCSCopyTextDefinition` | 0 | system |
| POS / lemma / entities | `NLTagger` | 0 | system |
| Pronunciation scoring | wav2vec2 phoneme model + goodness-of-pronunciation | ~0.4 GB | CoreML |
| TTS | Kokoro (fast, natural) / Chatterbox or F5-TTS (expressive) | 0.3–1 GB | CoreML or MLX |
| CEFR / frequency | bundled permissively licensed word lists | < 20 MB | — |
| Search | SQLite FTS5 | 0 | system |

Only the models marked **bold** are essential to the quality bar. The rest are either free
(system), already shipped (FluidAudio), or small.

## 3. Memory, and how to be greedy without swapping

24 GB unified; ~9 GB goes to macOS, the app and caches **[estimate]**, leaving ~15 GB.

```
监听时:  streaming ASR + VAD + ITN                     ~1.0 GB
分析时:  batch ASR ~1.6 + LLM 14B ~8.5 + 嵌入 0.5 + 其他  ~11 GB   ✓ 舒适
最优质:  batch ASR ~1.6 + Qwen3-30B-A3B ~17 + 其他       ~19 GB   ⚠ 需先释放 ASR 与缓存
```

Because the phases never overlap, the app's peak is the **max** of these, not their sum.
The mechanism is a small **model broker**: one component that knows every model's size,
loads on demand, evicts by recency, and refuses to load something that would not fit —
rather than letting each feature load whatever it likes.

Rules worth writing down now:

1. Never run batch ASR and the LLM at the same time.
2. Evict the streaming model whenever listening stops and analysis starts.
3. Qwen3-30B-A3B is a **mode**, not a default: it requires the "maximum quality" switch,
   and the app says plainly what it will unload.
4. Everything above 70B is out of reach at 4-bit (~40 GB) — do not design around it.

## 4. Runtimes this adds

Three at most, and ideally two:

- **CoreML / ANE** — already used; ASR, VAD, diarisation, alignment, pronunciation, TTS.
- **MLX Swift** — LLMs, translation, embeddings. The Apple-supported route for local LLMs.
- **whisper.cpp / WhisperKit** — only if the batch ASR choice lands on Whisper rather than
  the Parakeet model we already have. Avoid if possible: it is one more thing to build.

No Python. A shipped app must not depend on a Python environment, which rules out the
PyTorch-native versions of pyannote and several TTS models unless they are converted.

## 5. Honest gaps

**Dependency / syntactic parsing** is still the one soft spot. `NLTagger` gives POS and
lemmas; a real tree needs a converted parser. With the quality-first brief, the options
are now: convert a small dependency parser to CoreML/ONNX (a real project, a few days), or
ask the main LLM to parse a single sentence on demand in the inspector. Recommendation:
**do the LLM parse first**, because it also *explains* the sentence, which is what a
learner actually wants, and revisit a dedicated parser only if it proves insufficient.

**Pronunciation scoring** moves from "gap" to "feasible but unproven": a wav2vec2 phoneme
model plus GOP scoring is a known technique, but I have not measured it on this machine.
Treat it as a phase-6 spike with a go/no-go, not a promise.

**Streaming translation** stays out of scope: translation happens after the episode, per
paragraph. Live translated subtitles would reintroduce exactly the latency problem we
spent this whole session removing.

## 6. Licensing

- **FluidAudio** (Apache 2.0) already covers ASR, VAD, ITN, diarisation and several TTS
  engines. No new surface.
- **MLX** is MIT; **model weights carry their own licences** — Qwen is Apache 2.0, Gemma
  and Hunyuan have their own terms. Weights are **downloaded by the user, never
  redistributed**, which keeps the obligation with the model rather than with the app —
  the same pattern already used for the ASR models.
- **Word lists** remain the one unresolved redistribution question, and must be settled
  before the statistics phase.

## 7. What this changes about the plan

| Phase | Was | Now |
|---|---|---|
| 0 | persistence, history, export | unchanged |
| 1 | audio retention for replay | **audio retention is also the input to batch ASR — promote it** |
| 2 | text clean-up, LLM correction | **batch re-recognition first**; the LLM then corrects far less, and only where the two passes disagree |
| 3 | reader, dictionary, notes | unchanged |
| 4 | replay, slow-down, karaoke | word timings now come from the batch pass |
| 5 | statistics, SRS, Anki | unchanged, plus embeddings for semantic search |
| 6 | speaking: shadowing, then conversation | add the pronunciation-scoring spike |
| 7 | writing: summary, conversation | grade with the maximum-quality LLM, not the default one |

The ordering principle: **make the transcript correct before building anything on top of
it.** Every later feature inherits the transcription quality.
