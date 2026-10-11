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
- Shared bounded little-endian Float32 audio validation for Qwen and Silero.
- The macOS NSXPC request/reply signatures used by both actual consumers.

Model ownership, worker drain, ACK replay storage and inference scheduling stay
in the service. Client task ownership, microphone admission, transcript rendering
and ASRStreamingSession stay in the app. The package does not select production
backends, load models, retry admitted audio or choose a cloud fallback.

## Offline Silero contract

The four macOS-gated RPCs are `loadSilero`, `unloadSilero`,
`sileroSpeechTimestamps` and `cancelSileroRequest`. There are no Silero streaming
RPCs. Core ABI stays at 4; production VAD and HTTP routes are unchanged.

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
