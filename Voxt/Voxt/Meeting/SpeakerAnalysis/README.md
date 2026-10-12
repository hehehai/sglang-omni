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

File-feed failures, cancellation and slow-feed checks await owned stream cleanup
before releasing the inference permit. A noncooperative asset/progress callback
cannot be forced to return. Ordinary HTTP close remains its existing socket
operation, not a new Native drain barrier. Default routing, cached weights and
MLX Audio package linkage remain unchanged.
