# CPU realtime contract tests

From the repository root:

```sh
python -m pytest -q -rs sglang_omni_mlx/native/ci/test_realtime.py
```

Requires pytest, a C++20 compiler, and an installed `nlohmann/json.hpp` or
`NLOHMANN_JSON_INCLUDE_DIR` pointing to an include root containing that header.
Missing compiler/header dependencies produce explicit pytest skips. Tests never
fetch dependencies. For an offline run, provision dependencies beforehand.
The tested single-header dependency is nlohmann JSON **v3.11.3**, SHA-256
`9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6`.
Keep provisioned headers outside the repository.

Like `test_native_core.py`, use `CXX` and `OMNI_ABI_SANITIZERS`:

```sh
CXX=g++ OMNI_ABI_SANITIZERS=address,undefined \
  python -m pytest -q -rs sglang_omni_mlx/native/ci/test_realtime.py
CXX=clang++ OMNI_ABI_SANITIZERS=address,undefined \
  python -m pytest -q -rs sglang_omni_mlx/native/ci/test_realtime.py
```

## Independently replay BEFORE and AFTER

The 14 HTTP cases always compare current code with `baseline_outputs.json`.
An additional 14 tests build and replay the original real source when
`OMNI_REALTIME_BASELINE_DIR` is set. Without it, only these live BEFORE tests skip;
the recorded HTTP checks and 14 direct engine tests still run.

Recover the baseline from local Git history, without network access:

```sh
export OMNI_REALTIME_BASELINE_DIR="$(mktemp -d)"
revision=f2e2cf41bc5d7bb32704b4432c91fb2a4c2ff36b
for extension in cpp h; do
  git show "$revision:sglang_omni_mlx/native/src/realtime.$extension" \
    > "$OMNI_REALTIME_BASELINE_DIR/baseline-realtime.$extension"
done
python -m pytest -q -rs sglang_omni_mlx/native/ci/test_realtime.py
```

A shallow checkout needs these two source files supplied separately. Their hashes:

- `baseline-realtime.cpp`: `a38c94baea9fa6e050985b7b9e62c753595134189aa00188f0b4d758b111bc31`
- `baseline-realtime.h`: `f7bd4691cd987ec3b255bb0dd91ea86be9b5d33148a71d673074d78a41822a01`

The recorded outputs were produced by compiling these unmodified baseline files
with the same harness and stand-ins. They contain public wire events, Handle
return values, decode inputs/options, retained-prefix requests, and observed
cancellation. Only random `event_id` values are removed, after checking their
format. Event indices, ordering, text, segment IDs, final flags, every audio
sample, and every decode option remain exact. Live replay checks both binaries
against the recorded outputs; it does not silently regenerate expectations.

## Coverage and limits

- Manual-turn updates/errors; PCM16/base64 validation and permissive filtering.
- Empty/silent completion; multiple explicit commits; English/CJK joining.
- Leading-silence cadence, partial replacement and duplicate suppression.
- Multiple automatic max-length cuts, exact-boundary commits, tail samples.
- Per-segment language snapshots and inferred language carried between decodes.
- Prefix after two attempts, five-token rollback, failure/recovery behavior.
- Blocked preview with commit, close/cancellation, and late-result suppression;
  Close wakes Commit/Finish without waiting for an uncooperative model to drain.
- Direct float engine input without PCM quantization, typed events, empty append,
  silence threshold, invalid settings, post-finish commands, destruction during
  decode, and Close invoked by the event sink.

The compiler receives byte-identical copies of production `worker.cpp/.h`,
`realtime.cpp/.h`, and `realtime_engine.cpp/.h`. Copying into a temporary build
directory is necessary: quoted transcriber/audio includes otherwise select the
real MLX/model headers before test include directories. No production source is
rewritten or conditionally patched. Baseline builds omit the engine source.

Only inference dependencies are stand-ins: scripted transcription, ASCII
one-byte token rollback, a deliberately limited language-name table, Unicode
text helpers, scalar silence detection, and no-op MLX synchronize/cache calls.
The real worker schedules all decodes. Model gates use condition variables;
worker FIFO fences drain callbacks. Async command-start promises coordinate
commit tests. Five-second waits and subprocess deadlines only bound failures;
there are no arbitrary sleeps or elapsed-time correctness assertions.

These are **CPU algorithm and JSON adapter contract tests**, not GPU/model golden
recognition, real tokenizer validation, an HTTP/WebSocket network server test,
or XPC/macOS/full realtime acceptance. Existing model golden suites remain the
appropriate place for actual inference parity.
