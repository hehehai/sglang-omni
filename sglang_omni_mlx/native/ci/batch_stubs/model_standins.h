// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "backend.h"

namespace mlx::core {
struct array {};
} // namespace mlx::core
namespace whisper {
using WhisperModel = batch_test::Model;
}
namespace cohere_transcribe {
using CohereModel = batch_test::Model;
}
namespace moss {
using MossTranscribeDiarize = batch_test::Model;
}
namespace nemotron {
using NemotronModel = batch_test::Model;
struct LayerCache {};
struct LstmState {};
} // namespace nemotron
namespace parakeet {
using ParakeetModel = batch_test::Model;
}
namespace sensevoice {
using SenseVoiceModel = batch_test::Model;
}
namespace qwen3_asr {
struct Qwen3ASR {};
} // namespace qwen3_asr
