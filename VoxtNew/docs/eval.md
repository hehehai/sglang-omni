# Evaluating the curated models (M3)

VoxtNew ships a few curated models with parameters we tune, so their quality is measured, not assumed. This page has the eval set, how to run it, the numbers from mac-air, and the decisions they led to. The models and their settings are in [llm-models.md](llm-models.md) and `internal/omni/models.go`; how VoxtNew differs from Voxt is in [behavior.md](behavior.md).

## The eval set

`testdata/eval/`: 20 short clips (130 s, 4 MB of 16 kHz mono WAV) and two long ones joined from them.

| set | clips | what | example |
|---|---|---|---|
| `zh-filler` | 5 | Chinese dictation with fillers and self-corrections | 嗯，那个，我们下周二，呃不对，下周三下午三点开个会，讨论一下预算。 |
| `zh-plain` | 1 | Chinese without either | 今天的天气很好，我们下午去公园散步，晚上一起吃饭吧。 |
| `en` | 5 | English, two with fillers and corrections | Let's ship the release on Friday, no wait, on Thursday morning. |
| `mix` | 4 | Chinese with English words | 我们的服务用 Kubernetes 部署，CPU 占用太高了，需要 scale out。 |
| `dict` | 5 | the dictionary's terms (made-up product names, jargon) | VoxtNew 的新版本用 MLX 在本地跑语音模型。 |
| `long` | 2 | 95 s (13 Chinese and mixed clips) and 104 s (14 clips, starting in English), 0.8 s of silence between clips | |

- **Each clip** has its words (`text`), the expected clean-up (`clean`) and checks: phrases the clean-up keeps (`must`) or drops (`mustNot`: fillers, what a self-correction replaced), the same for an English translation of the Chinese clips (`mustEn`, `mustNotEn`), its dictionary terms (`terms`), and for the dictionary clips the transcript a speech model wrote without the dictionary (`heard`).
- **The dictionary** of every run is the set's nine terms (VoxtNew, MLX, AudioSmith, Pixcall, ActNow, Silero, SGLang, Qwen3, Auralink), with one alias ("Or Link" for Auralink).
- **The voices** are Qwen3-TTS (0.6B CustomVoice, Apache-2.0: Vivian, Serena and Uncle_Fu for Chinese, Ryan and Aiden for English), run by AudioSmith's engine through `internal/tools/evalsynth`. That tool writes files and never plays them. macOS `say` was the first idea, but its voices' terms do not clearly allow redistributing their output. The clips are therefore studio-clean synthetic speech: no noise, no accents, no real hesitation. Real dictation will score worse.
- **Each clip was checked** against both speech models. Takes that the TTS truncated or garbled were made again with another seed (`zh-filler-2`, `zh-filler-5`, `dict-5`). Two quirks remain:
  - the TTS reads 部署 in `dict-4` so that both models hear 注入;
  - "UI" in `mix-4` sometimes comes out as 友爱.
- **The speech sample** `testdata/speech/sample-zh-en.wav` was made again the same way. The old take said "Auralink"; the new one says "VoxtNew", as its golden text does, though its voice says it close to "Fox New", which is what both models write, even with the dictionary.

### Scores (`internal/eval`)

- **Error rate.** Both texts are normalised first: full-width characters, case, Chinese numerals as digits ("三百五十" = "350"), English number words ("twelve" = 12), and punctuation and fillers dropped from both sides. The error rate is then edits over the reference's tokens. A token is a Chinese character or a Latin word. So the rate is a CER on Chinese, a WER on English, and both on mixed speech.
- **Terms written** counts the clip's dictionary terms that the text writes exactly as the dictionary does.
- **Clean-up checks.** An answer has a fault when:
  - fillers are left;
  - a correction is missed: it keeps a replaced phrase, or loses a kept one;
  - it invents more than one token found in neither the input nor the expected answer (numbers aside);
  - it changes the language: its share of Chinese moves more than 30 points from the input's;
  - it copies the example: 4 Chinese characters or 5 words in a row from compose's example answer, absent from the input.

## Running it

On mac-air, from the persistent models and runtimes:

| path | what | refresh |
|---|---|---|
| `~/voxtnew-models/<id>/` | the six catalogue models, about 9 GB, installed by VoxtNew's models package (`TestRealInstall`, adopting the HF cache) | its `README.md` |
| `~/voxtnew-runtime/{omni,llm}/` | `scripts/build-omni.sh --out` and `scripts/build-llm.sh --out` from `voxtnew/dev` | its `README.md` |

```sh
# the whole eval, about 25 minutes; tables in build/eval (asr.md, llm.md, glossary.md)
MAC_DIR=code/VoxtNew-xyz scripts/mac.sh 'VOXTNEW_EVAL=1 VOXTNEW_OMNI_RUNTIME=$HOME/voxtnew-runtime/omni \
  VOXTNEW_LLM=$HOME/voxtnew-runtime/llm/voxtnew-llm VOXTNEW_EVAL_OUT=build/eval go test -count=1 -timeout 2h -run TestEval -v .'
# quick: a clip of each kind, checked against floors (part of scripts/mac-regress.sh)
… VOXTNEW_EVAL_QUICK=1 …
# some clips only
… VOXTNEW_EVAL_ONLY=dict-1,dict-5 …
```

The tests are:
- `TestEvalASR`: `eval_asr_test.go`;
- `TestEvalLLM` and `TestEvalGlossary`: `eval_llm_test.go` and `eval_glossary_test.go`;
- `TestEvalAppEnhancement` and `TestEvalDictionary`: `eval_e2e_test.go`.

They log a `CONTENTION` line when another `voxtnew-llm` or `qwen3_asr_server` was running before they started, since that skews the times. The numbers below come from runs without one at their start. mac-air is shared, though: other apps' engines (AudioSmith, Dicta) and another thread's runs were seen during the day, with swap in use. Read the times as upper bounds, and compare them only with runs on the same machine. `scripts/mac-regress.sh` (manual-test.md §10.6) runs the quick eval with the other Mac tests.

## Speech recognition

mac-air (M4, 24 GB, macOS 26.7), 2026-10-17; Finals with the eval dictionary as the context bias.

### Error rate by language hint

The user's main language is Chinese in all of these. "main zh" is Voxt's policy and VoxtNew's: the main language is always the hint. "none" lets the model detect the language. "main en" is the hint a user whose main language is English sends.

| clips (tokens) | `asr.accurate` main zh | none | main en | `asr.fast` main zh | none | main en |
|---|---|---|---|---|---|---|
| zh-filler (118) | 1.7% | 1.7% | 1.7% | 2.5% | 2.5% | 1.7% |
| zh-plain (23) | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% |
| en (72) | **0.0%** | 0.0% | 0.0% | **1.4%** | 1.4% | 1.4% |
| mix (70) | 2.9% | 2.9% | 0.0% | 11.4% | 11.4% | 8.6% |
| dict (59) | 11.9% | 11.9% | 11.9% | 20.3% | 20.3% | 20.3% |
| long-zh, 95 s | 1.6% | 1.6% | 1.6% | 6.3% | 6.3% | 6.3% |
| long-all, 104 s, starts in English | **2.9%** | **60.5%** | 60.1% | 4.2% | 3.8% | 3.8% |
| all (832) | **2.6%** | 19.1% | 18.8% | 6.0% | 5.9% | 5.5% |

- **The main language as the hint costs nothing on English.** Every English clip came out in English under "zh", on both models. Qwen3-ASR does not translate English to fit a Chinese hint.
- **Detection can go badly wrong on a mixed dictation.** Without a hint, `asr.accurate` took the long clip that starts in English for English, then translated all of its Chinese into English (60% errors). `asr.fast` did not.
- **A wrong hint does the same.** With the hint "en", `asr.fast` wrote two Chinese clips in English: 39% errors on `zh-filler`. That was in an earlier run with other takes of `zh-filler-2` and `zh-filler-5`; the final takes did not show it.

**Decision: keep (a), Voxt's policy.** The main language is the hint even when the user lists other languages (`session.speechLang`, `TestSpeechLang`). Option (b), no hint when other languages are set, would gain nothing on these clips and loses whole sentences on mixed speech. The open risk is the mirror case: a user whose main language is English and who dictates Chinese on `asr.fast` (Decisions needed in the handoff).

### The dictionary as context bias

Terms written exactly, of the 10 in the `dict` clips:

| | with the dictionary | without |
|---|---|---|
| `asr.accurate` | **7** | 4 |
| `asr.fast` | **4** | 3 |

- "VoxtNew" is fixed by the bias on `asr.accurate`: without it the model writes "Vox Tunew" or "Vox New".
- "SGLang" is fixed too: "S G Long" without it.
- "ActNow" (written "Act Now") and "Auralink" ("Or Link") are not fixed with nine terms in the context.
- In a whole session with only three terms, `asr.accurate` did write "Auralink". A small dictionary biases harder.
- `asr.fast` gains less from the bias.

### Times

| | `asr.accurate` (1.7B 8-bit) | `asr.fast` (0.6B 4-bit) |
|---|---|---|
| first Final (cold: the server starts and loads) | 1.16 s | 0.68 s |
| warm Final, short clips (6.5 s of audio on average) | median 648 ms, max 974 ms | median 218 ms, max 322 ms |
| Final of a long clip (95–104 s) | 8.6 s | 2.8 s |
| live: first partial after the speech starts (clip sent in real time) | median 153 ms, max 167 ms | median 69 ms, max 86 ms |
| live: the Final after Stop | median 672 ms, max 1.1 s | median 228 ms, max 327 ms |

- **Long dictation waits.** The live session's Final runs again over all the audio (Voxt's "offline Final is authoritative", behavior.md 3.7). A 100-second dictation on `asr.accurate` therefore waits 8.6 s after Stop.
- **Idle unload.** The 10-minute idle unload stays. A cold start costs 0.7–1.2 s, and it overlaps the user's speech, because the opener warms the model when the session starts.

## Clean-up with the small language models

Transcribe's clean-up of each clip's words, as said, with the user's main language from the clip and the eval dictionary as the glossary. Before M3, compose sent the clean-up rules alone; M3 adds an example turn (`compose.Example`). The example is a short dictation and its clean answer, sent as an earlier user and assistant message, one per template set:

| set | example input | example answer |
|---|---|---|
| zh-Hans | 呃，帮我把那个周报，嗯，发给小王，不对，是发给小李，今天下班前。 | 帮我把周报发给小李，今天下班前。 |
| en | Um, can you send the, uh, the weekly report to Tom, sorry, I mean to Anna, before five? | Can you send the weekly report to Anna before 5? |

### Transcribe, 20 short clips

| model | prompt | no fault | fillers left | corrections missed | copied the example | error vs expected | first token (median) | total (median) |
|---|---|---|---|---|---|---|---|---|
| `llm.balanced` | rules only | 18 | 0 | 2 | – | 7.0% | 1.89 s | 2.66 s |
| `llm.balanced` | **with the example** | **18** | 0 | 2 | 0 | **5.6%** | 2.05 s | 2.72 s |
| `llm.fast` | rules only | 14 | 4 | 6 | – | 13.6% | 0.93 s | 1.17 s |
| `llm.fast` | **with the example** | **16** | **1** | **3** | 0 | **9.9%** | 1.01 s | 1.23 s |

- **Both models keep two faults.** 就是说 is kept as a word. 那个报告周五之前发给我就行，不对，是周四之前 keeps both days: a correction at the end of the sentence.
- **`llm.fast` also has its own faults.** With the example, it once dropped the number it should have kept ("三百，五百" for "三百五十").

### Spoken Translate into English, 6 Chinese clips

| model | prompt | no fault | median total |
|---|---|---|---|
| `llm.balanced` | rules only | 4 | 3.37 s |
| `llm.balanced` | **with the example** | **6** | 3.64 s |
| `llm.fast` | rules only | 2 | 1.35 s |
| `llm.fast` | **with the example** | **6** | 1.38 s |

The faults without the example were the self-corrections kept and "uh" left in. No answer copied the example. A check that took three shared words for a copy ("Please send the report to me by Thursday") was too strict: it now needs five words in a row.

**Decision: the example turn is in.** It applies to Transcribe and spoken Translate, with Cleanup on, for both template sets. For Translate, the example is sent only when the target is English or Simplified Chinese, the two languages the example's answer is written in.
- `llm.fast` gains the most: its faultless clean-ups go from 14 to 16 of 20, and its translations from 2 to 6 of 6.
- `llm.balanced`'s translations go from 4 to 6 of 6. Its clean-ups stay at 18 of 20, a little closer to the expected text.
- It costs about 80–160 ms more of the first token: the example is about 60 more prompt tokens.
- compose's golden prompts show the turn (`internal/compose/testdata/golden`).

### Long dictation (two clips, 95–104 s)

- **Both models translate long mixed dictation into English.**
  - `llm.balanced`, with or without the example, turned the clip that starts in English entirely into English: "changed the language", 32% errors.
  - `llm.fast` did the same without the example.
  - With the example, `llm.fast` kept the language but left most fillers in both long clips.
- **Long clean-ups are slow.** `llm.balanced` takes 12.6–12.8 s and `llm.fast` about 5 s.
- This is not fixed in M3: see Decisions needed in the handoff (clean up long text in pieces, or not at all over a length).

### Spoken Translate with Hy-MT2 (`llm.translate`)

Hy-MT2 takes its own prompt and no clean-up rules (behavior.md 3.13). Raw speech, the same speech without its fillers, and `llm.balanced`'s clean-up first:

| input | no fault | fillers left | corrections missed | median total |
|---|---|---|---|---|
| raw speech | 2 | 2 ("well", "Ah", "um") | 3 | 0.55 s |
| **without fillers** (`compose.StripFillers`) | 3 | **0** | 3 | 0.46 s |
| `llm.balanced`'s clean-up first | 5 | 0 | 1 | 0.44 s, plus the clean-up's 2.7 s and loading two models |

**Decision: Hy-MT2 gets the speech without its fillers.**
- `compose.StripFillers` is deterministic and needs no model. It drops 嗯 呃 额 唔 and um uh er hmm anywhere. It drops 啊, 哦, 那个 and 就是说 only at the start of a clause, before a pause or a correction.
- The session puts that text in `llm.Request.Translate` for speech; a selection is sent as it is.
- **Clean-up first was rejected.** It wins on self-corrections, but `voxtnew-llm` holds one model at a time, so every spoken translation would load the 4B model and Hy-MT2 in turn: about 1.5 s of loading and 2.7 s of clean-up for a 0.5 s translation.
- **The trade-off for the user.** Self-corrections reach Hy-MT2 as spoken ("next Tuesday, no, next Wednesday"). A user who wants them resolved picks a general model for Translate: `llm.balanced` with the example got 6 of 6 in 3.6 s, `llm.fast` 6 of 6 in 1.4 s.

### The glossary on misheard terms (`TestEvalGlossary`)

Each dictionary clip's transcript as a speech model wrote it without the dictionary (`heard`), cleaned up with the eval dictionary as the glossary:

| model | terms written | terms put in where none was said (2 clips without terms) |
|---|---|---|
| `llm.balanced` | **9 of 10** | 0 |
| `llm.fast` | 5 of 10 | 0 |

- `llm.balanced` turns "Vox Tunew", "Voxnu", "Vox New", "S G Long", "Pixcal" and "Act Now" into the dictionary's spellings.
- It misses "Or Link" for "Auralink", although that is the term's alias: it keeps it as a name. A more insistent glossary wording changed nothing (the same 9 and 5 of 10), so compose's wording stays.
- `llm.fast` mostly ignores the glossary, as M2 saw.

## App enhancement and the dictionary, whole sessions on the real models

These are `eval_e2e_test.go`.

**Setup:**
- the app's own Library and runtimes, with `asr.accurate`, Silero and `llm.balanced` linked from `~/voxtnew-models`;
- the fake helper plays an eval clip as the recording, with an app in front;
- each session runs in an app of its own, quit before the next one.

Each session took about 6.5 s end to end, cold starts included: ASR 0.7–1.0 s and LLM 2.3–2.5 s after Stop.

| test | session | heard | result |
|---|---|---|---|
| App enhancement | `en-3`, Slack in front: the group "Casual chat: write everything in lowercase letters, with no period at the end." (`transcribe:cleanup+scene`) | Please remind me to call the dentist tomorrow at nine in the morning. | please remind me to call the dentist tomorrow at 9 in the morning |
| | the same in TextEdit: no group (`transcribe:cleanup`) | (the same) | Please remind me to call the dentist tomorrow at 9 in the morning. |
| Dictionary | `dict-1`, the dictionary on | VoxtNew的新版本用MLX在本地跑语音模型。 | VoxtNew 的新版本用 MLX 在本地跑语音模型。 |
| | the terms not sent to the speech model (glossary only) | Vox Tunew的新版本用MLX在本地跑语音模型。 | **VoxtNew** 的新版本用 MLX 在本地跑语音模型。 |
| | the dictionary off | Vox Tunew的新版本用MLX在本地跑语音模型。 | Vox Tunew 的新版本用 MLX 在本地跑语音模型。 |

## Not measured here

- Noise, real voices and accents.
- Recordings from a microphone.
- Sessions that run through the helper's real capture.
- Rewrite's quality.
- Translation into languages other than English.
- `TestMacE2EOmni` covers the live path with the real helper on the speech sample; scripts/mac-regress.sh runs it.
