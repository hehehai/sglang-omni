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

Model ownership, worker drain, ACK replay storage and inference scheduling stay
in the service. Client task ownership, microphone admission, transcript rendering
and ASRStreamingSession stay in the app. The package does not select production
backends, load models, retry admitted audio or choose a cloud fallback.

## Offline Silero contract

The four macOS-gated RPCs are `loadSilero`, `unloadSilero`,
`sileroSpeechTimestamps` and `cancelSileroRequest`. The streaming extension below
shares the same model owner. Current Core ABI is 5; production VAD and HTTP routes
are unchanged.

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

## Sortformer transport schema prerequisite

The Foundation types are implemented; Sortformer RPC selectors, helper engine
and App client are **not yet connected**. This schema checkpoint does not add
an executable XPC route or switch production diarization.

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
speaker summary. Cancellation is not drain; future helper/client paths must
preserve explicit terminal drain/destruction and no automatic audio replay.
Actual signed NSXPC/Metal/model acceptance remains pending.

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
