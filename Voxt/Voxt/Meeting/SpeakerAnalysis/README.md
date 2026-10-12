# Speaker Analysis

Speaker diarization models, labels, settings, and display helpers for meeting transcripts.

## Responsibilities

- Configures diarization engines and model managers used by meeting speaker detection.
- Maps speaker turns to stable labels and readable display names.
- Stores speaker-analysis settings and shared models used by meeting processing.

## Transport ownership

The default `SortformerMeetingSpeakerDiarizationEngine` preserves existing
Native HTTP routing when enabled and otherwise delegates to the isolated
`MLXSortformerMeetingSpeakerDiarizationEngine`. Neither the common protocol nor
the Native HTTP implementation imports MLX Audio. `MeetingSortformerConfiguration`
reads a bounded Foundation-only projection of scheduling fields; it is not model
compatibility or shared-directory authorization.

`MeetingSpeakerDiarizationEngineFactory.makeXPC` is explicit opt-in and requires
an already loaded model, client and corresponding configuration. The external
owner retains and eventually unloads that model; the adapter closes only its own
streams. It rejects timing geometry outside ABI5's 16 kHz/hop160/subsampling8 AOSC
contract and feeds at most 32000 real samples, without invented padding/tail.
This differs from the existing approximately five-second HTTP chunking and needs
real numerical/model validation before production cutover.

The legacy meeting engine and realtime annotation stage now keep a paired Swift
model/directory reader through construction, cached ownership and each active
operation. Clearing a cache or resetting the realtime stage does not release an
in-flight model's reader; model destruction precedes release. Directory selection
preserves existing readable-root order and rejects busy/unsafe acquisition rather
than silently changing caches. This is cooperating filesystem ownership, not a
new Swift MLX/GPU cancellation or drain API. Legacy Silero and cache/blob repair
paths still need coordination.

`OmniXPCSortformerModelOwner` explicitly prepares a caller-supplied shared Models
directory under a reader lease and supplies the matching model/configuration to
borrowed consumers. Retain the owner and await `close()`. Preparation and model
retirement use identity-bound owned coordinator permits; unconfirmed cleanup or
connection loss retains the lane, reader and original scope for retry. Cached
model residency is not an active command, so successful preparation releases its
command permit while keeping the reader. Cleanup is pressure/recording nondeferrable
but cannot overtake active inference. Borrowed operations must finish/cancel first.
There is no owner/token deinit resource barrier or automatic lane recovery.
The XPC adapter now holds identity-owned permits for open/feed/close and retains
its bounded provisional-start ticket on unconfirmed cleanup. Concrete engine
`close()` is an explicit retry barrier; dropping it is not disposal. The Owner's
`makeSpeakerAnalysisEngine()` caches that engine, and Owner close permanently
retires it before acquiring the model-cleanup permit, so late borrowed work
cannot reopen it or deadlock behind its retained command lane. The raw factory
returns the concrete engine so callers can await cleanup. Default production
factories remain unchanged.

File-feed failures, cancellation and slow-feed checks await owned stream cleanup
before releasing the inference permit. A noncooperative asset/progress callback
cannot be forced to return. Ordinary HTTP close remains its existing socket
operation, not a new Native drain barrier. Default routing, cached weights and
MLX Audio package linkage remain unchanged.
