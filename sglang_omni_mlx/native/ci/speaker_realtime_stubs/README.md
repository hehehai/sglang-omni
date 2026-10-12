# Speaker realtime CPU replay

`test_speaker_realtime.py` compiles the actual worker, MOSS/Nemotron HTTP
adapters, typed engines and speaker-event serializer with explicitly scripted
model/transcriber/audio/MLX boundary stand-ins. Model numerics, tokenizer, Metal,
macOS SDK, Native ABI and XPC transport are not validated by this fixture.

The immutable Before revision is `77a919c577753876bb7cb5331aa1ffa082553d66`.
Both live Before/After replay and `baseline.json.xz` compare 29 ordinary HTTP
scenarios. The archive contains full observable model-call inputs/options and
HTTP outputs; only random event IDs are removed. Tests never regenerate it.
Archive SHA256: `76b0557458a63e10df323eefd0da527b0847c48b7df715db7bd55e3448518d38`.
Uncompressed JSON SHA256: `5a87be5c884bc2cce09f495f01bb721fd00b511d3c3a2d951206434422ac3562`.

The separate lifetime cases use controlled model/publication gates. They verify
cancel/wakeup/event ordering and retain models until the actual worker drains.
Close and destruction are not GPU/resource barriers. The session-duration guard
uses a sampling-rate hook, not 24 hours of real 16 kHz audio; cadence uses the
actual steady clock, not a production clock replacement.

For concurrent HTTP error/preview Close tests only, the After serializer's
function name is renamed in the build copy. `serialization_observer.cpp` records
preview sink entry and forwards every event to the unchanged serializer body.
Both original and compiled source hashes are recorded. This notification-only
hook makes the two-thread transport/engine lock inversion deterministic, without
adding a production hook or replacing serialization logic. The variants also
cover a sender throwing after Close. Other tests leave the observer disabled.

Run from the repository with an installed C++20 compiler and JSON 3.11.3:

```sh
CXX=clang++ NLOHMANN_JSON_INCLUDE_DIR=<installed-json-include-root> \
  python3 -m pytest -q sglang_omni_mlx/native/ci/test_speaker_realtime.py
```

Optional `OMNI_SPEAKER_SANITIZERS=address,undefined,float-cast-overflow` enables
compiler sanitizers. Missing dependencies or the historical Git revision fail
explicitly; the tests never download dependencies. Constructor/model bad_alloc
and streambuf/publication gates are fault hooks, not genuine allocation pressure
or real acoustic golden validation.
