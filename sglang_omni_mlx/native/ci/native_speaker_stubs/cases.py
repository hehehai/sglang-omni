# SPDX-License-Identifier: Apache-2.0
"""Independent native speaker boundary cases and the exact published exports."""

EXPORTS = {
    "omni_speaker_settings_default",
    "omni_speaker_create",
    "omni_speaker_cancel",
    "omni_speaker_destroy_checked",
    "omni_speaker_realtime_create",
    "omni_speaker_realtime_push",
    "omni_speaker_realtime_commit",
    "omni_speaker_realtime_finish",
    "omni_speaker_realtime_poll",
    "omni_speaker_realtime_cancel",
    "omni_speaker_realtime_drain",
    "omni_speaker_realtime_destroy_checked",
    "omni_speaker_realtime_event_free",
}
PROTOCOL = (
    "defaults",
    "mapping",
    "snapshot_ownership",
    "empty_segments",
    "empty_finish",
    "commit",
    "copy_settings",
    "maximum_settings",
    "full_session",
)
VALIDATION = (
    "nulls",
    "directory_null",
    "directory_empty",
    "directory_long",
    "directory_8192",
    "directory_missing",
    "directory_utf8",
    "settings_null",
    "settings_long",
    "settings_utf8",
    "session_zero",
    "wrong_kind",
    "audio_null",
    "audio_empty",
    "audio_nan",
    "audio_inf",
    "ack_null",
    "chunk_limit",
    "total_limit",
    "sequence_zero",
    "sequence_gap",
    "sequence_repeat",
)
OUTPUTS = (
    "text_limit",
    "segment_text_limit",
    "text_utf8",
    "text_nul",
    "metadata_utf8",
    "metadata_nul",
    "speaker_limit",
    "language_limit",
    "emotion_limit",
    "event_limit",
    "segments_limit",
    "time_nan",
    "time_inf",
    "time_negative",
    "time_reversed",
    "aggregate_limit",
    "exact_bounds",
    "exact_aggregate",
    "aggregate_one_over",
    "unicode_bounds",
    "queue_slots",
    "queue_bytes",
)
LIFETIME = (
    "load_blocked",
    "load_failure",
    "load_failure_retained",
    "worker_cancel",
    "lease_completed",
    "lease_drained",
    "stream_cancel",
    "model_cancel",
    "stream_cleanup_retry",
    "model_cleanup_retry",
    "decode_failure",
    "decode_allocation",
    "blocked_decode",
    "blocked_finish",
    "blocked_callback",
    "blocked_sink",
    "blocked_sync",
    "late_stream_sync",
    "late_model_sync",
    "stream_cache_failure",
    "model_cache_failure",
)
CASES = (
    tuple(
        (kind, category, case)
        for kind in (1, 2)
        for category, cases in (
            ("protocol", PROTOCOL),
            ("validation", VALIDATION),
            ("outputs", OUTPUTS),
            ("lifetime", LIFETIME),
        )
        for case in cases
    )
    + ((1, "validation", "settings_prompt"),)
    + tuple(
        (2, "validation", case)
        for case in (
            "settings_flag",
            "settings_negative_flag",
            "settings_absent_chunk",
            "settings_nan",
            "settings_inf",
            "settings_zero",
            "settings_negative",
            "settings_chunk_limit",
        )
    )
    + tuple(
        (2, "protocol", f"chunk_{milliseconds}")
        for milliseconds in (1, 120, 240, 440, 840, 5000, 120000)
    )
    + (
        (2, "lifetime", "stream_failure"),
        (2, "lifetime", "stream_failure_retained"),
    )
)
