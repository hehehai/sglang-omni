# Transcription

Transcription engine adapters, local model managers, model artifacts, and shared transcriber contracts.

## Responsibilities

- Implements MLX, Speech, remote ASR, and legacy Whisper migration integration points.
- Manages local ASR model discovery, downloads, repository state, and artifact validation.
- Provides common transcriber protocols, support types, and post-processing for transcript text.

ASR model construction is in `MLXSTTModelLoader`. Catalog/state values and reusable resumable transfer live under `Core/Models`; `MLXModelDownloadSupport` retains ASR metadata/validation and tokenizer-asset policy. Managers continue to own install/download state, storage revision and load lifetimes.

## Native HTTP ownership

`OmniASRRuntime` owns process state, active uses and a cooperating model-directory
reader. It acquires that reader before spawning any ASR, Silero or Sortformer
server, uses the canonical directory, and retains it until the child actually
exits. A live process retains its runtime even if the last caller drops it.
Retirement still requires explicit awaiting; shutdown/termination deadlines
escalate signals, but cannot report a stopped process or free its reader while
it remains running. An uninterruptible child can therefore delay retirement.

`OmniASRRuntimeSupport` contains endpoint/configuration values, diagnostics and
line buffering; `OmniASRRuntimeFinalRequests` contains unchanged family-specific
request construction. Directory locks protect cooperating normal operation,
not external blob writes, uncoordinated namespace replacement, or an app crash
that releases its locks before an orphaned server finishes parent-death cleanup.
Legacy Swift readers and repair/shadow-cache maintenance are not all coordinated.

## Explicit batch model ownership

`OmniXPCBatchModelOwner` prepares a caller-supplied shared Models directory,
retains an App reader through model residency, and requires explicit preparation
before bounded final transcription. Loading and requests reserve identity-owned
file/final ASR coordinator permits. A successful command releases its lane while
keeping the cached model/reader; error or cancellation drains the original model
scope before release. Failed or lost cleanup retains the reader/reference/permit
for explicit owner close retry, never replay, implicit reload or retarget.
Close is permanent, uncancelled and coalesced; it cancels and awaits active work
before retirement and reuses a retained permit instead of queuing behind itself.
Retain the owner and await close; deinit is not a Native resource barrier.
This remains opt-in, at most 30 seconds per final request. Default HTTP/meeting
routing, longform/realtime migration, model choices and Audio dependencies are
unchanged; actual SDK/NSXPC/Metal acceptance remains pending.

## Explicit speaker realtime ownership

`OmniXPCSpeakerModelOwner` explicitly prepares a shared Models directory and
starts a bounded MOSS/Nemotron session. Unlike synchronous final requests, push
returns an admission ACK while Native decoding may still be queued or active.
The owner therefore retains one identity-owned coordinator permit throughout the
session, not one permit per command. Completion events and empty polls do not
release it. Checked session close releases the lane, preserving resident model
readers; explicit permanent model close drains the original load scope before
releasing readers. Failed/unknown cleanup retains the same identities and permit
for retry, never implicitly reconnecting, reloading or replaying audio.

Load tickets distinguish never-submitted RPCs from ambiguous admitted work;
pre-send rejection cannot drain another owner's model. Closed sessions/models
are identity-scoped and cleanup tasks are uncancelled and coalesced. Await close
while retaining the owner; deinit is not a barrier. Finite mono16k chunks contain
1...32000 samples, with at most 480000 samples per session. These are opt-in
transport bounds, not production recording limits or longform support.
Core/helper/App require matched ABI10 artifacts. Production factories remain
unchanged; scoped real SDK/Metal checks do not establish signed NSXPC acceptance.

`OmniXPCSpeakerStreamingSession.open(owner:settings:)` consumes an explicitly
prepared Owner through the actual `ASRStreamingSession` seam. It permanently
closes that entrusted Owner before publishing ended, preserving all segment
metadata and Double timing. MOSS uses existing line joining; Nemotron uses
existing script-aware joining. Input uses the existing bounded Float32 buffer;
transport chunk splitting is not longform segmentation or automatic replay.
Use `consumeEvents(until:)` or explicitly await `closeAndWait()` on early return
and cancellation. Failed cleanup retains the same adapter/Owner for retry;
checked permanent Owner-close notification also releases retention when retry
is initiated externally. Presentation end/deinit are not cleanup barriers.

The optional signed smoke invokes this consumer before and after helper restart
only when all three SPEAKER kind/model/expected source environment inputs are
supplied. It stages Models through App preparation, requires an explicit UTF-8
expected transcript, and retains unknown cleanup. This is not a production
meeting/recording factory switch; the legacy runtime's task-only retirement must
not be mistaken for this adapter's Native barrier.

## MLX boundaries

`MLXTranscriber` owns recording tasks, revision checks, model leases and capture-buffer instances. Pure policy is in `MLXTranscriptionPlanning`, `MLXInferenceConfiguration`, `MLXTranscriptMerging`, and `MLXLiveTextPreview`. Shared values, buffers, detached inference and structured segment conversion live in their correspondingly named files.

`MLXCorrectionPassCoordinator` owns the one in-flight correction pass. Cancelling a pass does not free its slot until the task has exited; final passes wait for retiring intermediate work. The transcriber still owns session revision and model leases, and verifies them after asynchronous inference/archive work.

`MLXNativeLiveRuntime` owns an installed stream, event/feed tasks and its transferred model use. For ASRRetiringStreamingSession it additionally awaits checked permanent Native retirement before releasing model use. Failure retains the original scope and use for explicit retry. Actual Owner-close notification waits for final event consumption before retiring an abandoned runtime, and cannot retire its replacement. Other transports retain task-only retirement semantics. Setup, session loops/finalization/preload/watchdogs and early prewarm use tracked-task stores so cancelled work remains visible during shutdown and blocks idle reclamation until exit. Audio-engine startup cancellation requests stop, but still waits for the native start call; this is not a hard native-exit deadline.

Transport task completion, synchronous cancel, terminal events and empty polls are not native decode/Metal barriers. Only the explicitly entrusted retiring-session contract reaches the checked original-load barrier; verify the remaining transports separately.

Audio STT loaders, numerical decoding, streaming/result compatibility adapters and product links are retired. Native HTTP family behavior/long-form options remain unchanged. Model-loader lifecycle tests use an identity-only fixture that cannot transcribe; they are not an alternative inference implementation. Audio VAD/Core consumers still prevent full package unlink.

Keep `nonisolated` inference, cancellation propagation and the existing buffer locks intact when moving code. The source split does not introduce another model/session owner. See the [phase record](../../docs/RefactoringProgress.zh-CN.md) before changing runtime ownership.
