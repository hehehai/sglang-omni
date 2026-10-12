// SPDX-License-Identifier: Apache-2.0
#include "backend.h"

#include <cassert>
#include <chrono>
#include <limits>
#include <new>
#include <stdexcept>

#include "cohere_transcriber.h"
#include "moss_transcriber.h"
#include "nemotron_transcriber.h"
#include "parakeet_transcriber.h"
#include "sensevoice_transcriber.h"
#include "whisper_transcriber.h"

namespace batch_test {

std::atomic<int> load_count{0};
std::atomic<int> destroy_count{0};
std::atomic<int> transcribe_count{0};
std::atomic<bool> should_fail_load{false};
std::atomic<bool> should_fail_load_allocation{false};
std::atomic<OutputMode> output_mode{OutputMode::Normal};
std::mutex block_mutex;
std::condition_variable block_condition;
bool should_block = false;
bool has_entered = false;
bool can_return = false;
std::thread::id loading_thread;
std::thread::id execution_thread;
std::thread::id destruction_thread;
int last_model_kind = 0;
std::string last_language;
bool has_language = false;
std::string last_prompt;
bool has_prompt = false;
int last_maximum_token_count = 0;
bool has_maximum_token_count = false;
float last_temperature = 0;
bool last_punctuation = false;
bool last_end_stop = false;
bool last_loop_stop = false;
double last_chunk_duration_seconds = 0;
float last_minimum_chunk_duration_seconds = 0;
int last_chunk_frame_count = 0;
bool has_chunk_frame_count = false;
bool last_inverse_text_normalization = false;
size_t last_sample_count = 0;
float last_sample = 0;

Model::Model(const std::filesystem::path &model_directory)
    : owner_thread(std::this_thread::get_id()) {
  assert(!model_directory.empty());
  loading_thread = owner_thread;
  if (should_fail_load_allocation.load()) {
    throw std::bad_alloc();
  } else if (should_fail_load.load()) {
    throw std::runtime_error("PRIVATE model load failure");
  } else {
    ++load_count;
  }
}

Model::~Model() {
  assert(owner_thread == std::this_thread::get_id());
  destruction_thread = std::this_thread::get_id();
  ++destroy_count;
}

void BlockNextTranscription() {
  std::lock_guard lock(block_mutex);
  should_block = true;
  has_entered = false;
  can_return = false;
}

void WaitForTranscription() {
  std::unique_lock lock(block_mutex);
  assert(block_condition.wait_for(lock, std::chrono::seconds(5),
                                  [] { return has_entered; }));
}

void ReleaseTranscription() {
  std::lock_guard lock(block_mutex);
  can_return = true;
  block_condition.notify_all();
}

qwen3_asr::TranscriptionResult Result(const Model &model,
                                      const std::vector<float> &samples,
                                      const std::atomic<bool> &cancel) {
  assert(model.owner_thread == std::this_thread::get_id());
  execution_thread = std::this_thread::get_id();
  ++transcribe_count;
  last_sample_count = samples.size();
  last_sample = samples.back();
  {
    std::unique_lock lock(block_mutex);
    if (should_block) {
      has_entered = true;
      block_condition.notify_all();
      block_condition.wait(lock, [] { return can_return; });
      should_block = false;
    } else {
    }
  }
  if (cancel.load()) {
    throw qwen3_asr::TranscriptionCancelled();
  } else {
  }
  qwen3_asr::TranscriptionResult result{
      "héllo 世界",
      "en",
      3,
      qwen3_asr::FinishReason::kStop,
      {{0.125, 1.75, "S01", "héllo 世界", "en", "happy", "speech"},
       {1.75, 2.0, "", "", std::nullopt, std::string(""), std::nullopt}}};
  switch (output_mode.load()) {
  case OutputMode::Normal:
    break;
  case OutputMode::Empty:
    result = {};
    result.finish_reason = qwen3_asr::FinishReason::kLength;
    break;
  case OutputMode::Throw:
    throw std::runtime_error("PRIVATE inference failure");
  case OutputMode::OutOfMemory:
    throw std::bad_alloc();
  case OutputMode::TextLimit:
    result.text.assign(65537, 'x');
    break;
  case OutputMode::LanguageLimit:
    result.language = std::string(129, 'x');
    break;
  case OutputMode::SegmentLimit:
    result.segments.resize(513);
    break;
  case OutputMode::TokenLimit:
    result.generated_token_count = 4097;
    break;
  case OutputMode::NegativeTokens:
    result.generated_token_count = -1;
    break;
  case OutputMode::InvalidTime:
    result.segments[0].start_seconds = std::numeric_limits<double>::infinity();
    break;
  case OutputMode::ReversedTime:
    result.segments[0].end_seconds = 0;
    break;
  case OutputMode::MetadataLimit:
    result.segments[0].emotion = std::string(129, 'x');
    break;
  case OutputMode::AggregateLimit:
    result.segments.resize(8);
    for (auto &segment : result.segments) {
      segment.text.assign(65536, 'x');
    }
    break;
  case OutputMode::EmbeddedNull:
    result.text = std::string("x\0y", 3);
    break;
  case OutputMode::InvalidFinish:
    result.finish_reason = static_cast<qwen3_asr::FinishReason>(100);
    break;
  case OutputMode::Boundary:
    result.text.assign(65536, 'x');
    result.language = std::string(128, 'e');
    result.generated_token_count = 4096;
    result.segments.resize(512);
    result.segments[0].speaker.assign(128, 's');
    result.segments[0].emotion = std::string(128, 'h');
    result.segments[0].event = std::string(128, 'a');
    result.segments[0].language = std::string(128, 'e');
    break;
  }
  return result;
}

} // namespace batch_test

namespace whisper {
WhisperTranscriber::WhisperTranscriber(const std::filesystem::path &directory)
    : model_(directory) {}
qwen3_asr::TranscriptionResult
WhisperTranscriber::Transcribe(const std::vector<float> &samples,
                               const WhisperOptions &options,
                               const std::atomic<bool> &cancel) const {
  batch_test::last_model_kind = 1;
  batch_test::last_language = options.language;
  batch_test::last_maximum_token_count = options.max_new_tokens;
  batch_test::last_temperature = options.temperature;
  return batch_test::Result(model_, samples, cancel);
}
} // namespace whisper

namespace cohere_transcribe {
CohereTranscriber::CohereTranscriber(const std::filesystem::path &directory)
    : model_(directory) {}
qwen3_asr::TranscriptionResult
CohereTranscriber::Transcribe(const std::vector<float> &samples,
                              const CohereOptions &options,
                              const std::atomic<bool> &cancel) const {
  assert(options.voice_activity_detector == nullptr);
  batch_test::last_model_kind = 2;
  batch_test::last_language = options.language;
  batch_test::last_maximum_token_count = options.max_new_tokens;
  batch_test::last_temperature = options.temperature;
  batch_test::last_punctuation = options.use_punctuation;
  batch_test::last_chunk_duration_seconds = options.chunk_duration_seconds;
  batch_test::last_minimum_chunk_duration_seconds =
      options.min_chunk_duration_seconds;
  return batch_test::Result(model_, samples, cancel);
}
} // namespace cohere_transcribe

namespace moss {
MossTranscriber::MossTranscriber(const std::filesystem::path &directory)
    : model_(directory) {}
qwen3_asr::TranscriptionResult
MossTranscriber::Transcribe(const std::vector<float> &samples,
                            const MossOptions &options,
                            const std::atomic<bool> &cancel) const {
  assert(!options.window_offset_seconds);
  batch_test::last_model_kind = 3;
  batch_test::has_prompt = options.prompt.has_value();
  batch_test::last_prompt = options.prompt.value_or("");
  batch_test::has_maximum_token_count = options.max_new_tokens.has_value();
  batch_test::last_maximum_token_count = options.max_new_tokens.value_or(0);
  batch_test::last_end_stop = options.stop_at_end_of_text;
  batch_test::last_loop_stop = options.stop_on_token_loop;
  return batch_test::Result(model_, samples, cancel);
}
} // namespace moss

namespace nemotron {
NemotronTranscriber::NemotronTranscriber(const std::filesystem::path &directory)
    : model_(directory) {}
qwen3_asr::TranscriptionResult
NemotronTranscriber::Transcribe(const std::vector<float> &samples,
                                const NemotronOptions &options,
                                const std::atomic<bool> &cancel) const {
  batch_test::last_model_kind = 4;
  batch_test::has_language = options.language.has_value();
  batch_test::last_language = options.language.value_or("");
  batch_test::has_chunk_frame_count = options.chunk_frames.has_value();
  batch_test::last_chunk_frame_count = options.chunk_frames.value_or(0);
  return batch_test::Result(model_, samples, cancel);
}
} // namespace nemotron

namespace parakeet {
ParakeetTranscriber::ParakeetTranscriber(const std::filesystem::path &directory)
    : model_(directory) {}
qwen3_asr::TranscriptionResult
ParakeetTranscriber::Transcribe(const std::vector<float> &samples,
                                const ParakeetOptions &options,
                                const std::atomic<bool> &cancel) const {
  batch_test::last_model_kind = 5;
  batch_test::last_chunk_duration_seconds = options.chunk_duration_seconds;
  return batch_test::Result(model_, samples, cancel);
}
} // namespace parakeet

namespace sensevoice {
SenseVoiceTranscriber::SenseVoiceTranscriber(
    const std::filesystem::path &directory)
    : model_(directory) {}
qwen3_asr::TranscriptionResult
SenseVoiceTranscriber::Transcribe(const std::vector<float> &samples,
                                  const SenseVoiceOptions &options,
                                  const std::atomic<bool> &cancel) const {
  assert(options.voice_activity_detector == nullptr);
  assert(options.max_chunk_seconds == 0 && options.chunk_overlap_seconds == 0);
  batch_test::last_model_kind = 6;
  batch_test::has_language = options.language.has_value();
  batch_test::last_language = options.language.value_or("");
  batch_test::last_inverse_text_normalization = options.use_itn;
  return batch_test::Result(model_, samples, cancel);
}
} // namespace sensevoice
