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

`TestLLMMeasure` (llm_measure_test.go) runs VoxtNew's own prompts (compose, real settings) twice per model after a warm load; `llm_e2e_test.go` runs whole Translate and Rewrite sessions (fake helper and speech model, the real process) through the dev hook. Rates are the generation's after the first token; the first token includes the prompt's evaluation. Second runs, which match the first within a few per cent (measured before the prompt cache, M2b below: now a second run is a hit):

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

## Prompt cache (M2b)

`voxtnew-llm` keeps an MLX model's caches (attention KV and Qwen3.5's linear-attention state) after the **shared prefix** of a prompt: everything before the last message's text, which for compose's prompts is the system prompt and, since M3, the clean-up's example turn (≈ 520–550 tokens for clean-up and spoken translation, ≈ 220 for translating a selection). A chat whose prompt starts with a kept prefix evaluates only the rest. How it works is in [llm-protocol.md](llm-protocol.md#the-prompt-cache); in short:

- Snapshots are reused whole, never trimmed (linear-attention state cannot be rewound). Up to 6 are kept (512 MB at most), the least recently used dropped first; they go with the model.
- The shared prefix is evaluated in chunks ending at multiples of 256 tokens and at its end, whatever the cache holds; snapshots are kept and reused only at those points. A greedy answer is then the same token for token with the cache on, off (`VOXTNEW_LLM_PROMPT_CACHE=0`), on a miss or on a hit: `TestLLMRealPromptCache` checks it on both models (5 prompt kinds × miss, hit with another input, hit with the same input), and the eval's answers with and without the cache are identical.
- compose's glossary lists the terms the text mentions first, so with a dictionary the system prompt changes from one dictation to the next at the glossary. A prompt that parts from a kept one inside the shared prefix keeps a **branch point** too (the last multiple of 256 before they part); the next such prompt starts there and evaluates the glossary, the output rules, the example and the text.
- **Warm-up.** While the user speaks, the session sends its own prompt with an empty text as a prefill chat (`maxTokens: 0`, `llm.Prefiller`, `session/run_listen.go` `warmLLM`): Transcribe's clean-up and Translate of speech; not Rewrite, whose prompt depends on the selection being read meanwhile. When the prefix is kept already the prefill costs a template render (a few ms); otherwise it is evaluated while the user speaks, and the chat after the recording is a hit.
- llama.cpp (Hy-MT2) makes a context per chat, and its prompts are 30–40 tokens with no system prompt (first token 0.06–0.11 s): nothing to gain, nothing done.

Measurements (mac-air, 2026-10-17, medians of `TestLLMMeasure` ×3, `TestLLMRealPromptCache` ×2 and the regression's run; resident meanwhile: the user's Dicta and AudioSmith engines, swap 12.3 of 13.3 GB used, 71 % memory free; generation at the M2 rates, so no GPU contention). First token, from the request to the first piece of text:

| | cold (miss) | hit | prefill (warm-up) |
|---|---|---|---|
| `llm.balanced`, clean-up and spoken translation (520–580 tokens) | 1.7–2.1 s | 0.26–0.29 s (0.16–0.32) | 1.9 s |
| `llm.balanced`, translating a selection (260 tokens) | 1.0 s | 0.27–0.28 s | – |
| `llm.fast`, clean-up and spoken translation | 0.66–0.81 s | 0.12–0.14 s (0.07–0.15) | 0.7 s |
| `llm.fast`, translating a selection | 0.39 s | 0.12–0.14 s | – |
| `llm.balanced`, rewriting (330–390 tokens; no warm-up) | 1.2–1.4 s | 0.16–0.27 s | – |
| `llm.fast`, rewriting | 0.48–0.56 s | 0.14 s | – |

A prompt that starts from a glossary's branch point (256 of 547 tokens) evaluates the other 290: under contention (another thread's eval running) `llm.fast` took 0.76 s against 1.3–1.4 s cold, `llm.balanced` about the same share. Rewrite has no warm-up, but its second request with the same system prompt is a hit like the others.

TestEvalLLM in quick mode (5 clean-ups, 2 spoken translations per model, one process, the cache on vs off): clean-up's median first token 2311 → 165 ms on `llm.balanced` and 965 → 100 ms on `llm.fast`, totals 2956 → 815 ms and 1191 → 324 ms; every MLX answer identical.

Memory: a snapshot of a ≈ 530-token prefix is 65 MB on `llm.balanced` (56 MB at 224 tokens: mostly the fixed linear-attention state) and 24 MB on `llm.fast`. Four prompt kinds kept cost +253 MB of MLX memory on `llm.balanced` (footprint 3.31 → 3.68 GB) and +106 MB on `llm.fast`; a prefill peaks at the same footprint as a chat.

## Not done yet

- A glossary that mentions the text's terms first still costs a partial evaluation (from the branch point) on every dictation that mentions a term; keeping the glossary in the dictionary's order when every term is listed would make those prompts hits too (a compose decision, see the M2b handoff).
