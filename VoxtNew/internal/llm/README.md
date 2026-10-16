# internal/llm

VoxtNew's chat-model layer: pure Go (standard library only), goroutine-safe, blocking — call it from goroutines, never from a build pass. Errors are `*llm.Error` with a stable `Code` and `Params`, never user text; they unwrap to `core.Err*` sentinels.

Taken from AudioSmith's `internal/llm` (@f171c86, Apache-2.0) and cut to what VoxtNew needs.

| Piece | API |
|---|---|
| Types | `Request{Model, Messages, Temperature, TopP, MaxTokens, Stop, Seed, Format, Schema, OnDelta, Timeout, Skill}`, `Response{Text, FinishReason, Model, Provider, Usage, Latency, Attempts, Repairs, JSON}`, `Usage`, `ModelInfo` |
| Backend (one attempt) | `Backend{Info(); Chat(ctx, Request); Models(ctx)}`; `OnDelta != nil` streams (SSE) |
| Transports | `NewOpenAI(preset, *http.Client, Secrets)` (chat/completions + /models; json_schema / json_object / prompt modes; asks again without `stream_options`, `temperature`/`top_p` or the preset's `extraBody` when a server rejects them), `NewAnthropic(...)` (Messages API) |
| Presets (data) | `presets.json`, in the Model services page's order (table below). `Presets()`, `LookupPreset`, `ProviderConfig{ID, Preset, Name, BaseURL, Model, Headers, JSONMode, ExtraBody}.Resolve()`: https only, plain http only to a loopback host, no user or password in the URL |
| Keys | `Secrets{Secret(ctx, name)}` → `ErrNoSecret` when absent; names `llm.<provider>` (`Preset.SecretName()`), the Keychain accounts of `internal/secrets`; `StaticSecrets`, `EnvSecrets` (`VOXTNEW_LLM_<ID>`, dev), `SecretsFunc` |
| Client | `Client{Backend, Timeout, Retry, Meter, Sleep}`: `Chat` (per-attempt timeout, retries 429/5xx/529/timeouts/resets with full-jitter backoff, honours Retry-After up to 60 s, never retries after streamed text, strips `<think>` blocks incl. from deltas, estimates usage when absent), `JSON(ctx, req, &out, repairs)` (extract → validate `Schema` → decode, repair turns quoting the errors) |
| Probe | `Probe(ctx, backend, model)`: the connection test — one non-streamed request with `max_tokens` 8, no retries; a reply cut short counts as working, 400/422 do not (with the server's detail) |
| Schema | `Object/Array/String/Number/Integer/Boolean/Enum`, `.Range`, `.Count`, `.Describe`, `Nullable`, `Closed`; `Validate`, `ExtractJSON` |
| Usage | `Meter` (per provider/model/skill: calls, failures, attempts, tokens, elapsed; `OnRecord`), `EstimateTokens` |
| Routing | `Skill`: `transcribe_enhance`, `translate_text`, `rewrite`; `DefaultTemperature` 0.1 / 0.2 / 0.5. `Routing{Default, Skills}` (internal/providers builds it from the features' settings). `Registry` (`Configure([]ProviderConfig)`, `Register(id, Backend)`), `Router{Registry, Timeout, Retry, Meter}`: `Chat/JSON(ctx, skill, req…)` try routes in order (fallback on anything but cancellation or streamed output), `Routes/Available/ProvidersFor` |

## Presets

| id | Base URL | Default model | JSON | extraBody |
|---|---|---|---|---|
| deepseek | api.deepseek.com/v1 | deepseek-flash | object | `thinking: disabled` |
| dashscope, dashscope-intl | dashscope(-intl).aliyuncs.com/compatible-mode/v1 | qwen-plus | object | `enable_thinking: false` |
| volcengine | ark.cn-beijing.volces.com/api/v3 | doubao-seed-2-0-pro-260215 | prompt | `thinking: disabled` |
| moonshot, moonshot-intl | api.moonshot.cn/v1, api.moonshot.ai/v1 | kimi-k2.5 | object | `thinking: disabled` |
| zhipu | open.bigmodel.cn/api/paas/v4 | glm-4.5-air | object | `thinking: disabled` |
| minimax | api.minimaxi.com/v1 | MiniMax-M2.5 | prompt | — (its `<think>` is stripped) |
| stepfun | api.stepfun.com/v1 | step-3.5-flash | prompt | — |
| mimo | api.xiaomimimo.com/v1 | mimo-v2.5-pro | prompt | `thinking: disabled` |
| siliconflow(-intl) | api.siliconflow.cn/v1, .com | Qwen/Qwen3-32B | object | `enable_thinking: false` |
| openai | api.openai.com/v1 | gpt-4.1-mini | schema | — |
| anthropic | api.anthropic.com/v1 (Messages) | claude-sonnet-4-6 | prompt | — |
| gemini | generativelanguage.googleapis.com/v1beta/openai | gemini-2.5-flash | schema | `reasoning_effort: none` |
| openrouter, groq, xai, mistral, together, fireworks, cerebras, nvidia | as AudioSmith's | | | — |
| custom | the user's (https, or http on loopback) | the user's | prompt | — |

Models and endpoints of the four added presets (Volcengine Ark, MiniMax, StepFun, Xiaomi MiMo) follow Voxt @baa6f31 (`RemoteModelConfiguration.swift`, `RemoteLLMEndpoints.swift`), except MiniMax, which VoxtNew reaches through its OpenAI-compatible API (`/v1/chat/completions`) instead of the native `chatcompletion_v2`. Thinking is turned off by default wherever the provider lets a request do so, as Voxt's generation settings do: a voice-input reply is short, and thinking spends its budget and seconds before any text.

## Changes from AudioSmith

- Dropped: `local.go` (`EngineBackend`, the MLX engine), the dubbing skills (`translate`, `translate_cinematic`, `fit_rewrite`, `glossary_extract`, `dictation_cleanup`, `direction_parse`) and their parent chain, `Router.SetLocalOnly`, the Ollama and LM Studio presets (VoxtNew has no local models; `custom` may still point at a loopback server).
- Added: the skills above; presets volcengine, minimax, stepfun, mimo; `Preset.ExtraBody` (+ `ProviderConfig.ExtraBody`) and the retry without it; `Preset.KeyURL`; `Probe`; `Models` is the suggested list of every preset; https-only base URLs; "Model Not Exist" (DeepSeek) maps to `llm.model_not_found`.
- Renamed: `UserAgent` "VoxtNew", `EnvSecrets` prefix `VOXTNEW_`, OpenRouter's `HTTP-Referer`/`X-Title`.
