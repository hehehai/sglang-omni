# Speech sample of the end-to-end tests

`sample-zh-en.wav`: 10.5 seconds of speech mixing Chinese and English, as
a 16 kHz, mono, 16-bit PCM WAV file (44-byte header, no extra chunks). The
`TestE2E` tests of `internal/asr/{openai,doubao,aliyun}` and
`TestE2ESessionReal` recognise it with the real services when
`AURALINK_E2E=1` and their keys are set; without the file they skip. They
only check that the transcript is not empty; the golden text below is for
reading the logs.

## Golden text

```
今天下午三点开会，讨论 Auralink 的发布计划。Please send the meeting notes to the team.
```

"Auralink" is a made-up word, so services write it in several ways
(other takes of the same text came back as "Aura Link", "Oralink",
"R-Link", "Our Link"); a dictionary entry "Auralink" should fix that.

## Where it came from

Synthetic speech, no human voice:

- Model: [Qwen3-TTS-12Hz-0.6B-CustomVoice](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice)
  (Alibaba Qwen, **Apache-2.0**), in its MLX 8-bit conversion
  `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit`. Built-in speaker
  `Uncle_Fu`, seed 7, the whole golden text in one call.
- Engine: AudioSmith's `audiosmith-engine` 0.3.0 (mlx-audio-swift), the
  one-shot path, run on an M4 Mac on 2026-10-15:
  `audiosmith-engine --model mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit --voice Uncle_Fu --seed 7 --text "…" --output q.wav`
  (24 kHz mono float). AudioSmith adds no watermark on this path.
- Post-processing with SoX: trim leading and trailing silence (0.1 %
  threshold), 0.3 s of silence before and after, peak-normalise to −3 dBFS,
  resample to 16 kHz (`rate -v`), 16-bit with dither.

Apache-2.0 puts no condition on the model's outputs; the file is shipped
under this repository's licence (AGPL-3.0-or-later; NOTICE).

Checked with two local recognisers (AudioSmith's engine):

| Recogniser | Transcript |
|---|---|
| Whisper large-v3 turbo (4-bit) | 今天下午三点开会,讨论Auralink的发布计划。Please send the meeting notes to the team. |
| Qwen3-ASR 0.6B (4-bit) | 今天下午三点开会，讨论Aura Link的发布计划。Please send the meeting notes to the team. |

Kokoro-82M (Apache-2.0) was tried first, with every Chinese voice: its
Chinese front end reads "开会" as "开开会" and cannot say "Auralink", so
recognisers got "讨论" as "偷懒" and dropped or mangled the name.
Do not replace this file with macOS `say` output: its voices' terms do not
clearly allow redistribution.
