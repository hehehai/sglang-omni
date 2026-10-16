# The language models

VoxtNew runs three curated language models in `voxtnew-llm` ([llm/](../llm/README.md), [llm-protocol.md](llm-protocol.md)). Their catalogue entries (repository, revision, files) are `internal/models/catalog.go`; how they run is one table, `internal/llmrt/models.go`, sent with every chat (the process keeps no settings).

| id | model | runtime | what it does |
|---|---|---|---|
| `llm.balanced` (default) | `mlx-community/Qwen3.5-4B-OptiQ-4bit` (3.3 GB without `optiq/`) | MLX | clean-up, translation, rewriting |
| `llm.fast` | `mlx-community/Qwen3.5-2B-4bit` (1.75 GB) | MLX | the same, quicker and weaker |
| `llm.translate` | `tencent/Hy-MT2-1.8B-GGUF`, `Hy-MT2-1.8B-Q4_K_M.gguf` (1.13 GB) | GGUF (llama.cpp) | translation only, with its own prompt |

## Generation settings

| | `llm.balanced`, `llm.fast` | `llm.translate` |
|---|---|---|
| Clean-up (`transcribe_enhance`), translation | greedy (temperature 0, top-p 1), repetition penalty 1.05 over 32 tokens (Voxt's local runs) | temperature 0.7, top-p 0.6, top-k 20, repetition penalty 1.05 over 64 (its model card) |
| Rewriting | temperature 0.7, top-p 0.8, top-k 20, penalty 1.05 / 32 (Qwen's non-thinking recommendation) | refused (`llm.unsupported`) |
| Template | `enable_thinking: false` | the GGUF's own chat template |
| Prompt | compose's messages as they are | one user message: the card's "Translate the following text into <language> …" (Chinese prompt for Chinese), from `llm.Request.Translate` (`hymt.go`) |
| Answer budget | Voxt's: clean-up 1.10 × input characters + 128 (128–1024), translation 1.35 × + 160 (128–1024), rewriting 1.35 × + 192 (256–1536) | the translation budget, at most 2048 |
| Prompt chunk (MLX) | 256 under 1000 characters, 512 under 3000, else 768 (Voxt's) | – |

Every chat also has Voxt's repetition guard (a phrase repeated six times or more ends the answer, one copy kept). `llm.Client` strips a `<think>` block if one still comes, retries a crash once, and repairs JSON (Rewrite's answer card).

## Measurements (mac-air: M4, 24 GB, macOS 26.7; 2026-10-17)

`TestLLMMeasure` (llm_measure_test.go) runs VoxtNew's own prompts (compose, real settings) twice per model after a warm load; `llm_e2e_test.go` runs whole Translate and Rewrite sessions (fake helper and speech model, the real process) through the dev hook. Rates are the generation's after the first token; the first token includes the prompt's evaluation. Second runs, which match the first within a few per cent:

| model | load (process start included) | prompt evaluation | first token | generation | memory |
|---|---|---|---|---|---|
| `llm.balanced` | 0.86 s | ≈ 320 tokens/s | 0.85 s (262-token prompt) … 1.65 s (530) | 25–26 tokens/s | footprint 3.4 GB, peak 4.3 GB |
| `llm.fast` | 0.78 s | ≈ 800 tokens/s | 0.33 s (262) … 0.66 s (530) | 70–78 tokens/s | footprint 1.2 GB, peak 2.0 GB |
| `llm.translate` | 0.65 s warm (7.6 s the first time after the download: a cold disk and llama.cpp's Metal setup) | – | 0.06–0.11 s (28–41 tokens: no system prompt) | 52–58 tokens/s | resident 1.15 GB (the weights are mapped from the file; footprint 0.11 GB) |

Whole sessions (the session's own LLM time, from the request to the answer):

| session | model | result | time |
|---|---|---|---|
| Translate a selection, en → zh-Hans | `llm.balanced` | 早上好，团队。下午三点开会；请带上发布检查清单。 | 2.4 s (first token 1.06 s, 280 + 14 tokens, 25.9 tokens/s, peak 4.1 GB) |
| Rewrite a selection ("make this more polite and formal") | `llm.balanced` | Please send me the report by Friday. | 2.1 s (first token 1.39 s, 373 + 8 tokens, 23 tokens/s, peak 4.3 GB) |
| Translate a selection, zh → en | `llm.translate` | Today's weather is really nice. Let's meet at three o'clock. | 0.56–1.0 s (first token 63–78 ms, 52 tokens/s, resident 1.2 GB) |

A cancelled chat ends 15–25 ms after `job.cancel` (`TestLLMRealCancel`), and the process takes the next chat.

On the same Mac `mlx-community/Qwen3-4B-Instruct-2507-4bit` (from the HF cache, as `llm.balanced` through the dev hook) loaded in 0.5 s and generated 28–32 tokens/s with a 3.0 GB peak.

## How compose's prompts fare with these models

Translation and rewriting come out right with both Qwen3.5 models, and the JSON answer (Rewrite with nothing selected) parses on the first try. The weak spot is clean-up of Chinese dictation: with compose's prompts, which list the fillers to remove (嗯、呃、那个、就是说) and the self-corrections to resolve, both Qwen3.5 models keep most fillers ("嗯，那个我们下周二、下周三下午三点开个会…") and leave self-corrections; `llm.fast` also ignores the glossary (writes "voxt new", "m l x"). English clean-up is better but keeps "So," and, on `llm.fast`, the self-correction ("Friday; no, wait, Thursday"). Sampling does not change this (greedy, with and without the penalty, 0.3, 0.7). One example turn (a user message and its cleaned answer) before the input fixes most of it on both models (fillers and the correction removed, the glossary applied on `llm.fast` too), but `llm.fast` then once copied the example's answer instead of cleaning the input. Qwen3-4B-Instruct-2507 removes the fillers without an example (but resolved "下周二呃下周三" to the wrong day). See the handoff's decisions: an example in compose's clean-up layer, tested on a set of dictations, is the likely fix.

## Not done yet

- **Prompt caching.** compose's system prompt is the same for the same settings and is 250–500 tokens: it is most of the first token's time on `llm.balanced` (0.85–1.65 s). Keeping the model's cache after the system prompt and evaluating only the user message would bring the first token near 0.2 s. Qwen3.5 mixes attention and linear-attention layers, whose state cannot be trimmed back, so the cache must be snapshotted at the end of the system prompt; mlx-swift-lm's own prompt-cache reuse is internal at this revision.
