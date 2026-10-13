# OmniXPCContracts

Foundation-only contracts shared by the Voxt app and OmniInference service.
The local package has no model, MLX, HTTP, AppKit, or application dependency.
NSXPC protocol declarations are compiled only on macOS; validation and codecs
run directly on Linux and macOS.

```text
Voxt app ─────────────────┐
                         ├─ OmniXPCContracts (Foundation)
OmniInference service ───┘
  └─ Native Core C ABI ── realtime engine / model worker
```

## Responsibilities

- Signing configuration and shared-model directory validation.
- Bounded final audio assembly and connection/model/session references.
- Realtime settings, strict wire-event/batch shape and size validation.
- Offline Silero settings, distinct connection/model references and bounded sample-timestamp batches.
- Silero stream references and bounded per-command probability batches.
- Sortformer settings, model/stream references and bounded four-speaker result codecs.
- Shared bounded little-endian Float32 audio validation for Qwen and Silero.
- The macOS NSXPC request/reply signatures used by both actual consumers.

ABI7 adds typed bounded final batch contracts for Whisper, Cohere, MOSS,
Nemotron, Parakeet and SenseVoice. Settings preserve each Native family's
Float/Double precision and defaults; results retain language, speaker, times,
emotion/event and generated-token/finish metadata. The helper directly calls
the existing transcribers, not HTTP. At most 30 seconds of finite mono16k input
is supported per final request; realtime/longform consumers remain pending.
Original-load identities, checked request/model release, non-evicting bounded
load tombstones and retained client claims keep errors/disconnects from falsely
acknowledging retirement. There is no automatic replay or retargeted cleanup.
Matched Core/helper/App artifacts must be rebuilt; an old Core cannot supply
these ten new exports. Portable peers/CPU workers are not signed NSXPC/Metal
acceptance, and default production routing remains unchanged.

Model ownership, worker drain, ACK replay storage and inference scheduling stay
in the service. Client task ownership, microphone admission, transcript rendering
and ASRStreamingSession stay in the app. The package does not select production
backends, load models, retry admitted audio or choose a cloud fallback.

## Bounded speaker realtime RPC (ABI10, opt-in)

The matched Core/helper/App epoch is now 10 (72 Native exports). The thirteen
bounded Native MOSS/Nemotron model/stream exports remain unchanged. ABI9 introduced
these ten actual macOS RPC selectors: loadSpeaker, unloadSpeaker,
drainSpeakerLoad, startSpeakerSession, pushSpeakerAudio, commitSpeakerSession,
finishSpeakerSession, pollSpeakerEvents, closeSpeakerSession and
cancelSpeakerRequest. Older artifacts, including epoch9, must not pass the compatibility gate.
`OmniXPCSpeakerKind` uses MOSS=1/Nemotron=2, distinct from batch model numbers.
References bind the complete model/service/connection/original-load UUID scope
and session UUID. The helper uses a private monotonic UInt64 Native session
counter, never UUID truncation/hash or automatic reconnect retargeting.

Immutable settings preserve optional prompt/language/chunk milliseconds and
require exact family fields. Event and poll codecs preserve preview segments
absent versus final/completed segments present (including empty), Double times,
metadata and positive overflow-safe UInt64 sequences. Full session equality,
terminal-last ordering, 512 segments, 64 events, UTF8/NUL-inclusive native string
budgets and independent encoded-byte budgets are enforced. Use bounded
encoded()/decode(_:) at the actual wire boundary, not raw Codable.

Native ingress remains finite mono16k, 1...32000 samples/chunk and at most
480000 samples per session. This is a validation-route transport bound, not
longform/model capacity. ACK, completed/cancelled events, empty polls or a DTO
isDrained value do not establish Native retirement. Helper/client ownership
retains original-scope handles/readers until actual checked worker/model barriers
succeed, including nonnull handles returned with failed creation. Non-evicting
load/session histories are bounded to 256 identities; failed cleanup is retryable
only in the original scope. Poll replays the complete retained batch until its
exact last sequence is acknowledged; audio is never automatically replayed.
Nemotron commit seals input, while MOSS commit permits later chunks.

OmniXPCSpeakerModelOwner retains one owned coordinator permit across the entire
session, including asynchronously admitted decoding. Checked session close
releases the lane while preserving resident model readers; original-load model
close releases those readers. Load tickets distinguish never-submitted work from
ambiguous admitted work. Retain owners and explicitly await close; disconnect,
deinit, cancel ACK and presentation completion cannot prove retirement.
Production factories remain unchanged. Portable client/helper/Core CPU evidence
is not actual macOS SDK, signed NSXPC, Metal or model numerical acceptance.

## Offline Silero contract

The five macOS-gated RPCs are `loadSilero`, `unloadSilero`,
`sileroSpeechTimestamps`, `cancelSileroRequest` and `drainSileroLoad`. The streaming
extension below shares the same model owner. Current Core ABI is 10; production
VAD and HTTP routes are unchanged.

Silero has checked model/stream destruction and checked creation with an owned
nonnull failure output after model construction begins. The helper registers a
reader-owning shell before loading; constructor exceptions and failed sync/cache
retirement retain it for original-scope retry. The connection's non-evicting
256-entry original-load ledger resolves successful unload and lost close replies.
Only actual checked original-load retirement releases reader/model/client claims;
disconnect, cancellation ACK and absent published models are not proof.

`OmniXPCSileroSettings` requires explicit threshold, minimum speech milliseconds,
minimum silence milliseconds and speech padding milliseconds; no native defaults
are invented. `validate()`, `encoded()` and `decode(_:)` enforce a finite threshold
in 0...1 and each duration in 0...30000 milliseconds. Settings JSON is limited to
1024 bytes; invalid input throws `OmniXPCFailure.error(.invalidRequest, ...)`.

`OmniXPCSileroTimestampBatch` carries service instance, model and request UUIDs,
input sample count, and `[startSample, endSample)` ranges in 16 kHz sample units,
not seconds. Its `encoded()` and `decode(_:)` enforce 1...480000 input samples,
at most 938 timestamps and 65536 JSON bytes. Ranges must have positive length,
be ordered and nonoverlapping, and lie inside the input; adjacent ranges and an
empty no-speech array are valid. Invalid responses throw `.incompatibleService`.
Both codecs require exact fields and numeric types; byte limits are checked
before JSON decoding, and timestamp counts before decoding range elements.
Use these bounded entry points at the wire boundary rather than raw Codable.

`OmniXPCSileroModelReference` is distinct from the Qwen model reference and carries
`modelID`, `serviceInstanceID` and `connectionID`. Consumers must enforce the
origin connection and compare response identity and sample count against the
submitted request; the codec alone cannot determine request ownership.

`OmniXPCRequestValidation.audioSamples(audio:maximumSampleCount:)` validates its
limit in 1...480000, checks byte bounds/alignment before allocating samples and
rejects nonfinite little-endian Float32 input. Existing Qwen `samples(...)`
continues to validate transcription options first, then uses the same parser.
The existing 16 kHz, 480000-sample and 256-requests-per-model protocol limits are
shared; admission, cancellation and request-history enforcement stay in the
service, not this package.

## Bounded Silero streaming contract

`startSileroStream`, `pushSileroAudio`, `finishSileroStream` and
`closeSileroStream` are four additional macOS RPCs. Start echoes the requested
stream UUID. Cancellation uses `cancelSileroRequest` with that stream UUID and
its model UUID; its ACK is **not** a drain barrier. Successful finish and close
replies are native drain/destruction barriers.

`OmniXPCSileroStreamReference` binds the stream UUID to the complete model
reference. `OmniXPCSileroProbabilityBatch` carries service/model/stream UUIDs,
`audioSequence`, cumulative `processedSampleCount`, `probabilities` and
`isFinal`. The codec requires exact fields and types, a positive active sequence
(or nonnegative final sequence), a 512-aligned UInt64 processed count, finite
probabilities in 0...1, at most 63 active probabilities or one final probability,
and at most 4096 encoded bytes. Empty probability arrays are valid. Counts are
checked before decoding elements. Consumers must also validate matching origin,
sequence, finality, cumulative count and the number of newly completed frames;
standalone DTO validation cannot establish those relationships.

Each audio command contains 1...32000 mono 16 kHz Float32 samples. Streams have
no 30-second lifetime cap; cumulative counters are overflow checked. There are
at most 16 live stream bindings, sharing the service's 256-request/stream history
budget per model. Service replay storage contains only the latest successful
push payload/reply; the client never automatically replays audio.

### App ownership (opt-in only)

Prefer `client.withSileroVoiceActivityStream(model:timeout:operation:)` for a
structured lifetime. Its operation receives an `OmniXPCVoiceActivityStream`
actor with `probability(samples16k:)`, `finish()` and async throwing `close()`.
Probability returns only the latest newly completed frame, or nil. Finish
explicitly pads the final partial frame. Overlapping feed/finish calls fail busy
rather than accumulating tasks. The helper awaits cleanup on return, throw and
cancellation; cancellation initiates scoped cleanup even if the operation is
suspended on unrelated work. Cleanup/barrier errors are surfaced, not rewritten
as drained success. The helper cannot force arbitrary noncooperative operation
code to return.

Raw actors from `open(client:model:timeout:)` and low-level stream references
require **explicit awaited close**. A retained raw stream does not detect caller
early return, dropping a reference, or cancellation between calls. There is no
claimed deinit barrier. Unclosed raw streams remain in the bounded client/service
live-stream tables until explicitly closed or the connection shuts down. Finish
success itself is a native barrier; a subsequent close is safe. Client close
idempotence retains only a bounded 256-reference tombstone cache, not probability
history; references evicted after later streams retire are rejected locally.
Disconnect initiates service cleanup but is not a client-observed native drain
ACK. Stale connection/model references never reset a healthy replacement or Qwen
model, and a Silero deadline never invalidates the healthy shared connection.

## Bounded Sortformer streaming contract (opt-in)

The eight actual RPCs are `loadSortformer`, `unloadSortformer`,
`drainSortformerLoad`, `startSortformerStream`, `pushSortformerAudio`,
`finishSortformerStream`, `closeSortformerStream` and `cancelSortformerRequest`. Helper Core leases and
App clients use this shared product directly. Production HTTP/meeting
factories are unchanged; opt-in wiring is not signed-platform acceptance.

### Load cleanup barrier

`drainSortformerLoad` uses the original load-operation UUID, never a guessed
model identity. Success follows Native creation completion, checked stream/model
destruction and reader release, or a closed no-resource load identity. A drain
received before a delayed load creates a closed tombstone so that load cannot
later admit. Each connection retains at most 256 load identities without eviction;
new IDs fail when full, while existing IDs remain drainable. Only one queued load
drain per connection is admitted. Closed old loads never affect replacements.

App loads retain one pending ticket and await an uncancelled scoped drain after
cancellation, deadline, malformed identity or Native error. A failed cleanup or
cleanup timeout retains that ticket and blocks replacement; use
`closePendingSortformerLoad(timeout:)` to retry on the originating connection.
Concurrent retries coalesce. A lost connection remains unconfirmed and cannot
retarget cleanup through a new connection. Cancel ACKs, deadlines and disconnects
are not resource barriers. No automatic model/audio replay or connection reset is
introduced, and coordinator ownership across failed loads is not yet switched.

Successful App loads also retain their original operation ID in one current
model binding. `closeSortformerModel(_:timeout:)` drains that original scope,
including provisional or live streams; retirement failure/deadline keeps the
binding for retry. Unload still rejects live streams, but a lost successful unload
reply can be resolved through the load tombstone rather than a guessed model ID.
New stream starts and late outputs are blocked while closing. Exact closed-model
references are idempotent within a 256-entry current-connection history; foreign
or evicted references are rejected. Connection loss clears those success-model
maps without proving Native release; a future external owner must retain its own
lease/reference/permit on that path. Retained coordinator permits are not wired
by this prerequisite.

ABI6 adds status-returning Sortformer model/stream destruction. On failure the
helper retains raw handles, leases and readers for retry, including cancelled
unpublished loads and failed unload. Legacy void C entry points and layouts are
preserved. Rebuild matching Core/helper/App artifacts: ABI5 must not pass the gate
for these new cleanup guarantees. This is not real Metal/SDK acceptance.

`OmniXPCSortformerSettings` requires explicit threshold, minimum duration and
merge gap in seconds, speaker-cache maximum frame count and FIFO maximum frame
count. It enforces finite threshold 0...1, durations 0...3600 seconds, cache
1...4096 and FIFO 0...4096, with a 1024-byte wire limit. Model-specific encoder,
compression and input-cap validation remains Native Core responsibility; these
general bounds do not certify checkpoint compatibility.

`OmniXPCSortformerModelReference` and `OmniXPCSortformerStreamReference` preserve
connection/service/model/stream identities. The result codec alone cannot prove
origin ownership, expected audio sequence or cumulative frame progression.

`OmniXPCSortformerProbabilityBatch` is a push-only result: 1...26 frames, four
speakers, exactly frame-count times four row-major finite probabilities in
0...1, at most 104 segments and 32768 wire bytes. Cumulative processed frames
are bounded by the Native Int32 counter, not received audio samples. Absolute
segment start/end seconds follow the actual model Float arithmetic before
widening to Double; overlapping speakers, equal starts and long-stream rounded
zero-length ranges remain valid. Unknown/missing fields, malformed shapes,
invalid values and out-of-batch/unsorted segments reject. Byte/count bounds
precede decoding arrays. Use `encoded()`/`decode(_:)` at the transport boundary;
raw Codable does not enforce the overall wire byte budget.

Native finish produces no extra audio, padded tail, probability batch or final
speaker summary. Successful finish/close replies follow checked Native
finish/cancel, drain and destruction; cancellation ACKs do not. Service state
is bounded to 16 live streams and 256 used stream IDs per model. Only the latest
successful push bytes and encoded reply are retained; exact last sequence and
bytes replay that reply without inference, while changed/future/old sequences
reject. Neither the client nor actor automatically resubmits audio.

`OmniXPCDiarizationStream.feed(samples16k:)` returns the actual whole probability
and segment batch. Use `client.withSortformerDiarizationStream` to await cleanup
on return, throw or cancellation; retained raw actors require explicit awaited
`close()`. One feed/finish may run at a time. Failed close remains terminal and
retains ownership, allowing the same actor to retry the barrier. Noncooperative
operation code cannot be forced to return by the structured scope.

Sortformer deadlines cancel only their originating operation/stream and preserve
healthy Qwen/Silero. Malformed successful load identities use the originating
connection and load-operation ID for scoped cleanup, never guess a model ID or
invalidate unrelated work. The cancellation ACK initiates cleanup; it is not a
Native resource barrier. Actual signed NSXPC/Metal/model acceptance remains
pending.

## Test independently

Requires Swift 6.2 or newer; no Xcode app build or model installation:

```sh
swift test --package-path Voxt/Packages/OmniXPCContracts
swift test --package-path Voxt/Packages/OmniXPCContracts -c release
```

These tests execute the real Foundation contracts with deterministic in-memory
settings, audio and timestamp fixtures, not NSXPC/platform substitutes. They cover
Silero serialization, required fields and types, invalid domains and ranges,
identity preservation, exact byte/count limits and shared-parser regressions.
The case-insensitive model-file test explicitly skips on a case-sensitive
filesystem. NSXPC/signing/App Group access, real model inference and concurrent
GPU/Metal behavior still require macOS integration validation.

## Integration

The Xcode project links the same local product into the app and service; consumers
import OmniXPCContracts directly. Shared source files are no longer separately
compiled into both targets. Native ABI version expectations must be rebuilt with
matching app/service/runtime artifacts. Realtime XPC remains opt-in validation;
production HTTP routing is unchanged at this checkpoint.
