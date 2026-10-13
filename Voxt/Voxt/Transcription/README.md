# Transcription

Native HTTP engine adapters, local model managers, model artifacts and shared transcriber contracts. Historical MLX-prefixed app types manage local ASR; they no longer imply a Swift Audio numerical backend.

## Responsibilities

- Routes local ASR through the existing Native HTTP/WebSocket servers, alongside Speech and Remote ASR.
- Manages ASR discovery, downloads, repository state and bounded artifact validation.
- Preserves family-specific requests, language/hints, structured segments, preview/final projection and longform behavior.

`OmniASRBackend` constructs the Native runtime. Catalog/state values and resumable transfer live under `Core/Models`; `MLXModelDownloadSupport` retains metadata/validation and tokenizer-asset policy. Managers own install/download state, storage revisions and load lifetimes. Lifecycle tests use identity-only fixtures that reject inference.

## Native HTTP ownership

`OmniASRRuntime` owns the child process, active uses and a cooperating canonical model-directory reader. It acquires the reader before spawning an ASR, Silero or Sortformer server and retains it until actual child exit. A running child retains its runtime after callers drop it. Shutdown escalates graceful exit to termination signals; deadlines cannot release readers while a process remains alive. Uninterruptible children can delay retirement.

`OmniASRRuntimeSupport` contains endpoint/configuration values, diagnostics and line buffering; `OmniASRRuntimeFinalRequests` retains family-specific requests. Endpoint uses close their exact scope. Network cancellation and task settlement are not per-stream GPU drain proof. Whole-model release is observable through process exit, without introducing new APIs into the shared Native package.

Directory leases protect cooperating operations, not external blob writes, uncoordinated namespace replacement or an App crash releasing locks before an orphaned child exits. Cache/blob/repair and parent-crash/orphan recovery are not all coordinated.

## App task ownership

`MLXTranscriber` owns recording tasks, revision checks, model leases and capture buffers. Pure policy lives in `MLXTranscriptionPlanning`, `MLXInferenceConfiguration`, `MLXTranscriptMerging` and `MLXLiveTextPreview`; detached inference and structured segment conversion have their own files.

`MLXCorrectionPassCoordinator` owns the in-flight correction slot until its task exits, including cancelled work. Final passes wait for retiring intermediate work; the transcriber rechecks revision/model use after suspension.

`MLXNativeLiveRuntime` owns the installed stream, feed/event tasks and transferred model use. Setup, finalization/preload/watchdogs and early prewarm retain cancelled tasks until settlement so shutdown can observe them. Audio-engine startup cancellation requests stop but still waits for the underlying start call. Neither that wait nor synchronous stream cancellation is a hard Native GPU-exit deadline.

## Dependencies and validation

Audio STT/VAD/Core loaders, numerical compatibility adapters, products and package pin are retired. XPC helper/client/contracts, validation configurations and the C ABI route are removed. Default production remains the unmodified Native HTTP implementation, not a new 30-second or bounded XPC route.

Keep model catalogs, saved choices and installed directories, MLX Swift LLM/VLM/MLX, Tokenizers/HuggingFace, llama.swift and Remote. Captured AudioCore DSP and independent model/sample-bound numerical references replace linked-library oracles; missing references skip parity explicitly.

Preserve actor isolation, nonisolated inference, cancellation propagation and existing buffer locks. See the [Native HTTP plan](../../plan/NativeHTTPMigrationPlan.zh-CN.md) and [earlier phase record](../../docs/RefactoringProgress.zh-CN.md) before changing ownership.
