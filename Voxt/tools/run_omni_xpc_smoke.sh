#!/usr/bin/env bash
# Runs the opt-in signed App, stages fixture data, then checks Native inference and restart.
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "Apple Silicon macOS is required for XPC/Metal validation." >&2
  exit 1
}
[[ $# -ge 4 && $# -le 6 ]] || {
  echo "usage: run_omni_xpc_smoke.sh <signed-app> <qwen-model-directory> <audio-file> <expected-transcript-file> [silero-model-directory] [sortformer-model-directory]" >&2
  echo "Optional batch: supply ALL of VOXT_OMNI_XPC_SMOKE_BATCH_KIND, VOXT_OMNI_XPC_SMOKE_BATCH_MODEL_SOURCE and VOXT_OMNI_XPC_SMOKE_BATCH_EXPECTED_SOURCE." >&2
  echo "Optional speaker: supply ALL of VOXT_OMNI_XPC_SMOKE_SPEAKER_KIND (1=moss, 2=nemotron), VOXT_OMNI_XPC_SMOKE_SPEAKER_MODEL_SOURCE and VOXT_OMNI_XPC_SMOKE_SPEAKER_EXPECTED_SOURCE." >&2
  echo "Batch kind: 1=whisper, 2=cohere, 3=moss, 4=nemotron, 5=parakeet, 6=sensevoice; expected source: nonempty UTF-8, <=65536 bytes." >&2
  exit 2
}
app="$1"
model="$2"
audio="$3"
expected="$4"
silero="${5:-}"
sortformer="${6:-}"
if [[ -n "$sortformer" && ! -f "$sortformer/config.json" ]]; then
  echo "The optional Sortformer model is missing config.json." >&2
  exit 1
fi
if [[ -n "$silero" && ! -f "$silero/config.json" ]]; then
  echo "The optional Silero model is missing config.json." >&2
  exit 1
fi
[[ -d "$app/Contents/XPCServices/OmniInference.xpc" ]] || {
  echo "The app does not contain OmniInference.xpc." >&2
  exit 1
}
[[ -f "$model/config.json" && -f "$audio" && -f "$expected" ]] || {
  echo "The model or fixture inputs are missing." >&2
  exit 1
}
command -v python3 >/dev/null || { echo "python3 is required only by this validation tool." >&2; exit 1; }
codesign --verify --deep --strict "$app"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
[[ -x "$app/Contents/MacOS/$executable" ]] || { echo "The signed app executable is missing." >&2; exit 1; }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
afconvert "$audio" -f WAVE -d LEI16@16000 -c 1 "$scratch/input.wav"

python3 - "$app/Contents/MacOS/$executable" "$model" "$scratch/input.wav" "$expected" "$silero" "$sortformer" <<'PY'
import array
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import uuid
import wave

executable, model, audio, expected, silero, sortformer = sys.argv[1:]
environment = {
    key: value for key, value in os.environ.items()
    if not key.startswith(('DYLD_', '__XPC_DYLD_', 'VOXT_OMNI_XPC_SMOKE_'))
    and key not in {'VOXT_OMNI_RUNTIME', 'VOXT_ASR_BACKEND', 'MLX_METAL_PATH'}
}

BATCH_FIELDS = (
    'VOXT_OMNI_XPC_SMOKE_BATCH_KIND',
    'VOXT_OMNI_XPC_SMOKE_BATCH_MODEL_SOURCE',
    'VOXT_OMNI_XPC_SMOKE_BATCH_EXPECTED_SOURCE',
)
SPEAKER_FIELDS = (
    'VOXT_OMNI_XPC_SMOKE_SPEAKER_KIND',
    'VOXT_OMNI_XPC_SMOKE_SPEAKER_MODEL_SOURCE',
    'VOXT_OMNI_XPC_SMOKE_SPEAKER_EXPECTED_SOURCE',
)
MAXIMUM_EXPECTED_BYTE_COUNT = 65_536


def fixture_environment(fields: tuple[str, str, str], allowed_kinds: set[str]) -> tuple[dict[str, str], int | None, bytes | None]:
    supplied = {field: os.environ[field] for field in fields if field in os.environ}
    if not supplied:
        return {}, None, None
    elif len(supplied) != len(fields) or not all(supplied.values()) or supplied[fields[0]] not in allowed_kinds:
        raise ValueError('Optional smoke requires all three explicit values and a canonical supported kind.')
    else:
        pass
    model_source = pathlib.Path(supplied[fields[1]]).resolve()
    expected_source = pathlib.Path(supplied[fields[2]]).resolve()
    if not model_source.is_dir() or not expected_source.is_file():
        raise ValueError('The optional model directory or expected transcript file is missing.')
    else:
        pass
    with expected_source.open('rb') as source:
        expected_bytes = source.read(MAXIMUM_EXPECTED_BYTE_COUNT + 1)
    if len(expected_bytes) > MAXIMUM_EXPECTED_BYTE_COUNT or not expected_bytes.decode('utf-8').strip():
        raise ValueError('The optional expected transcript must be nonempty UTF-8, at most 65536 bytes.')
    else:
        pass
    supplied[fields[1]] = str(model_source)
    supplied[fields[2]] = str(expected_source)
    return supplied, int(supplied[fields[0]]), expected_bytes


batch_environment, batch_kind, batch_expected_bytes = fixture_environment(BATCH_FIELDS, {'1', '2', '3', '4', '5', '6'})
speaker_environment, speaker_kind, speaker_expected_bytes = fixture_environment(SPEAKER_FIELDS, {'1', '2'})

def run(mode, run_id=None):
    overrides = dict(environment, VOXT_OMNI_XPC_SMOKE_MODE=mode)
    overrides.update(batch_environment)
    overrides.update(speaker_environment)
    if run_id is not None:
        overrides['VOXT_OMNI_XPC_SMOKE_RUN_ID'] = run_id
        if mode == 'stage':
            overrides['VOXT_OMNI_XPC_SMOKE_MODEL_SOURCE'] = str(pathlib.Path(model).resolve())
            if silero:
                overrides['VOXT_OMNI_XPC_SMOKE_SILERO_SOURCE'] = str(pathlib.Path(silero).resolve())
            else:
                pass
            if sortformer:
                overrides['VOXT_OMNI_XPC_SMOKE_SORTFORMER_SOURCE'] = str(pathlib.Path(sortformer).resolve())
            else:
                pass
        else:
            pass
        if silero:
            overrides['VOXT_OMNI_XPC_SMOKE_SILERO_DIRECTORY'] = f'Models/OmniXPCSileroSmoke/{run_id}'
        else:
            pass
        if sortformer:
            overrides['VOXT_OMNI_XPC_SMOKE_SORTFORMER_DIRECTORY'] = f'Models/OmniXPCSortformerSmoke/{run_id}'
        else:
            pass
    completed = subprocess.run(
        [executable], env=overrides, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=600, check=False,
    )
    reports = [line[len('VOXT_OMNI_XPC_RESULT '):] for line in completed.stdout.splitlines()
               if line.startswith('VOXT_OMNI_XPC_RESULT ')]
    if completed.returncode != 0 or len(reports) != 1:
        raise RuntimeError('The signed XPC smoke process failed; inspect macOS signing/service logs.')
    return json.loads(reports[0])

prepared = run('prepare')
expected_abi_version = 10
if prepared.get('status') != 'prepared' or prepared.get('abi_version') != expected_abi_version:
    raise RuntimeError('The signed service did not complete its ABI/container probe.')
container = pathlib.Path(prepared['group_container'])
if not container.is_absolute() or not container.is_dir():
    raise RuntimeError('The service returned an invalid App Group container.')
run_id = str(uuid.uuid4()).upper()
model_destination = container / 'Models' / 'OmniXPCSmoke' / run_id
artifacts = container / 'OmniXPCSmoke' / run_id
silero_destination = container / 'Models' / 'OmniXPCSileroSmoke' / run_id
sortformer_destination = container / 'Models' / 'OmniXPCSortformerSmoke' / run_id
destinations = [model_destination, artifacts]
if silero:
    destinations.append(silero_destination)
else:
    pass
if sortformer:
    destinations.append(sortformer_destination)
else:
    pass
if batch_kind is not None:
    destinations.append(container / 'Models' / 'OmniXPCBatchSmoke' / run_id)
else:
    pass
if speaker_kind is not None:
    destinations.append(container / 'Models' / 'OmniXPCSpeakerSmoke' / run_id)
else:
    pass
for destination in destinations:
    if not destination.resolve().is_relative_to(container.resolve()):
        raise RuntimeError('The smoke fixture destination is outside the shared container.')
    if destination.exists():
        raise RuntimeError('The smoke run directory already exists.')
passed = False
try:
    artifacts.mkdir(parents=True)
    if batch_expected_bytes is not None:
        (artifacts / 'batch-expected.txt').write_bytes(batch_expected_bytes)
    else:
        pass
    if speaker_expected_bytes is not None:
        (artifacts / 'speaker-expected.txt').write_bytes(speaker_expected_bytes)
    else:
        pass
    staged = run('stage', run_id)
    if staged.get('status') != 'prepared' or staged.get('abi_version') != expected_abi_version:
        raise RuntimeError('The signed app did not complete coordinated model preparation.')
    with wave.open(audio, 'rb') as source:
        if source.getnchannels() != 1 or source.getframerate() != 16000 or source.getsampwidth() != 2:
            raise RuntimeError('The converted fixture must be mono 16 kHz PCM16.')
        if source.getnframes() == 0 or source.getnframes() > 16000 * 30:
            raise RuntimeError('The validation fixture must contain between one sample and 30 seconds.')
        pcm = array.array('h', source.readframes(source.getnframes()))
    if sys.byteorder != 'little':
        pcm.byteswap()
    (artifacts / 'audio.f32').write_bytes(b''.join(struct.pack('<f', sample / 32768.0) for sample in pcm))
    expected_text = pathlib.Path(expected).read_text(encoding='utf-8').strip()
    if not expected_text:
        raise RuntimeError('A non-empty expected transcript is required.')
    (artifacts / 'expected.txt').write_text(expected_text, encoding='utf-8')
    report = run('infer', run_id)
    if report.get('status') != 'passed' or report.get('first_service_process_id') == report.get('restarted_service_process_id'):
        raise RuntimeError('Native inference or service restart did not pass.')
    if silero and (report.get('silero_request_count') != 4 or report.get('silero_stream_count') != 2):
        raise RuntimeError('The optional Silero offline/stream reuse/reconnect validation did not run.')
    else:
        pass
    if sortformer and (report.get('sortformer_stream_count') != 6 or report.get('sortformer_caller_count') != 2):
        raise RuntimeError('The optional Sortformer stream/caller reuse/reconnect validation did not run.')
    else:
        pass
    if batch_kind is not None and (
        type(report.get('batch_kind')) is not int or report.get('batch_kind') != batch_kind
        or report.get('batch_request_count') != 4 or report.get('batch_caller_count') != 2
    ):
        raise RuntimeError('The optional batch owner reuse/reconnect validation did not run.')
    else:
        pass
    if speaker_kind is not None and (
        type(report.get('speaker_kind')) is not int or report.get('speaker_kind') != speaker_kind
        or report.get('speaker_session_count') != 2 or report.get('speaker_caller_count') != 2
    ):
        raise RuntimeError('The optional speaker streaming consumer/reconnect validation did not run.')
    else:
        pass
    passed = True
    print(json.dumps(report, sort_keys=True))
finally:
    if passed:
        for destination in destinations:
            shutil.rmtree(destination)
    else:
        print('Smoke fixture data retained after failure; remove only after the XPC service is idle:', file=sys.stderr)
        print(*destinations, sep='\n', file=sys.stderr)
PY
