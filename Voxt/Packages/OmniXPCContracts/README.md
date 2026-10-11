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
- The macOS NSXPC request/reply signatures used by both actual consumers.

Model ownership, worker drain, ACK replay storage and inference scheduling stay
in the service. Client task ownership, microphone admission, transcript rendering
and ASRStreamingSession stay in the app. The package does not select production
backends, load models, retry admitted audio or choose a cloud fallback.

## Test independently

Requires Swift 6.2 or newer; no Xcode app build or model installation:

```sh
swift test --package-path Voxt/Packages/OmniXPCContracts
swift test --package-path Voxt/Packages/OmniXPCContracts -c release
```

These tests execute the real Foundation contracts, not NSXPC/platform substitutes.
The case-insensitive model-file test explicitly skips on a case-sensitive
filesystem. NSXPC/signing/App Group access and real Native inference still require
macOS integration validation.

## Integration

The Xcode project links the same local product into the app and service; consumers
import OmniXPCContracts directly. Shared source files are no longer separately
compiled into both targets. Native ABI version expectations must be rebuilt with
matching app/service/runtime artifacts. Realtime XPC remains opt-in validation;
production HTTP routing is unchanged at this checkpoint.
