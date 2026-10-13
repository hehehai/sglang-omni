# Speaker Analysis

Speaker diarization models, labels, settings, and display helpers for meeting transcripts.

## Responsibilities

- Configures diarization engines and model managers used by meeting speaker detection.
- Maps speaker turns to stable labels and readable display names.
- Stores speaker-analysis settings and shared models used by meeting processing.

## Transport ownership

The default `SortformerMeetingSpeakerDiarizationEngine` delegates to Native HTTP.
Unavailable Native throws explicitly; the Swift library fallback and Audio imports
are retired. `MeetingSortformerConfiguration`
reads a bounded Foundation-only projection of scheduling fields; it is not model
compatibility or shared-directory authorization.

`MeetingSpeakerDiarizationEngineFactory.makeXPC` is explicit opt-in and requires
an already loaded model, client and corresponding configuration. The external
owner retains and eventually unloads that model; the adapter closes only its own
streams. It rejects timing geometry outside ABI5's 16 kHz/hop160/subsampling8 AOSC
contract and feeds at most 32000 real samples, without invented padding/tail.
This differs from the existing approximately five-second HTTP chunking and needs
real numerical/model validation before production cutover.

The ordinary HTTP engine owns an exact runtime/model directory lease and
serializes sessions across suspension. File completion/failure retires that exact
process before releasing admission; shared endpoint reference counts or socket
cancellation are not Native-exit proof. Directory selection keeps readable-root
order and rejects busy/unsafe acquisition. The unused legacy realtime annotation
actor had no production caller/selector/resource and was deleted; no new 24-second
whole-window transport was added. Cache/blob/orphan recovery remains separate work.

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
operation, not a new Native drain barrier. Cached weights/catalog choices remain;
Audio package linkage is removed. Actual process exit retains the HTTP model reader.
