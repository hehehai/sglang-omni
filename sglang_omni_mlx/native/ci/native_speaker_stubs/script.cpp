// SPDX-License-Identifier: Apache-2.0
#include "moss_transcriber.h"
#include "nemotron_transcriber.h"
#include <cstring>

namespace native_test {
Script script;
void require(bool condition, const std::string &message) {
  if (!condition) {
    throw std::runtime_error(message);
  } else {
  }
}
void Gate::block() {
  std::unique_lock<std::mutex> lock(mutex);
  entered = true;
  changed.notify_all();
  require(changed.wait_for(lock, TIMEOUT_SECONDS, [&] { return released; }),
          "Gate release timed out");
}
void Gate::wait() {
  std::unique_lock<std::mutex> lock(mutex);
  require(changed.wait_for(lock, TIMEOUT_SECONDS, [&] { return entered; }),
          "Gate entry timed out");
}
void Gate::release() {
  std::lock_guard<std::mutex> lock(mutex);
  released = true;
  changed.notify_all();
}
void Script::record_thread(const char *operation) noexcept {
  std::lock_guard<std::mutex> lock(mutex);
  if (thread_count == threads.size()) {
    std::terminate();
  } else {
  }
  threads[thread_count++] = {operation, std::this_thread::get_id()};
}
void observe_thread(const char *operation) noexcept {
  script.record_thread(operation);
}
void sink_checkpoint(bool is_segment) {
  if (is_segment && script.blocks_sink.load()) {
    script.sink_gate.block();
  } else {
  }
}
void finish_checkpoint() {
  if (script.blocks_finish.load()) {
    script.finish_gate.block();
  } else {
  }
}
void callback_finished() {
  observe_thread("callback.complete");
  if (script.blocks_callback.load()) {
    script.callback_gate.block();
  } else {
  }
  std::lock_guard<std::mutex> lock(script.mutex);
  ++script.finished_callbacks;
  script.changed.notify_all();
}
void wait_callbacks(int expected_count) {
  std::unique_lock<std::mutex> lock(script.mutex);
  require(script.changed.wait_for(lock, TIMEOUT_SECONDS,
                                  [&] {
                                    return script.finished_callbacks.load() >=
                                           expected_count;
                                  }),
          "Actual worker callback completion timed out");
}
void Script::record(nlohmann::ordered_json call) {
  std::lock_guard<std::mutex> lock(mutex);
  calls.push_back(std::move(call));
  changed.notify_all();
}
nlohmann::ordered_json Script::snapshot() {
  std::lock_guard<std::mutex> lock(mutex);
  return calls;
}
qwen3_asr::TranscriptionResult Script::decode(nlohmann::ordered_json call,
                                              const std::atomic<bool> &cancel) {
  observe_thread("inference");
  call["cancelled_at_entry"] = cancel.load();
  record(std::move(call));
  const int decode_number = ++decode_count;
  if (blocks_decode.load()) {
    decode_gate.block();
  } else {
  }
  if (fails_allocation) {
    throw std::bad_alloc();
  } else if (fails_decode) {
    throw std::runtime_error("PRIVATE model/path/audio");
  } else {
  }
  std::lock_guard<std::mutex> lock(mutex);
  auto decoded = output;
  if (varies_text) {
    decoded.text += std::to_string(decode_number);
  } else {
  }
  return decoded;
}
qwen3_asr::TranscriptionResult result(const std::string &text) {
  return {
      text,
      "result-language",
      7,
      qwen3_asr::FinishReason::kStop,
      {{0.125, 0.875, "S03", "segment", "en-US", "neutral", "speech"},
       {0.875, 1.0, "", "tail", std::nullopt, std::string{}, std::nullopt}}};
}
std::vector<float> audio(size_t sample_count, size_t offset_samples) {
  std::vector<float> samples(sample_count);
  for (size_t i = 0; i < sample_count; ++i) {
    samples[i] = static_cast<float>(
                     static_cast<int>((i + offset_samples) % 4096) - 2048) /
                 1234.5f;
  }
  return samples;
}
void check_threads() {
  std::lock_guard<std::mutex> lock(script.mutex);
  std::thread::id model_thread;
  for (size_t i = 0; i < script.thread_count; ++i) {
    if (std::strcmp(script.threads[i].operation, "model.construct") == 0) {
      model_thread = script.threads[i].thread;
      break;
    } else {
    }
  }
  require(model_thread != std::thread::id{}, "No loading thread observed");
  require(model_thread != std::this_thread::get_id(),
          "Model loaded on API caller");
  size_t model_constructions = 0;
  size_t model_destructions = 0;
  for (size_t i = 0; i < script.thread_count; ++i) {
    const auto &observation = script.threads[i];
    model_constructions +=
        std::strcmp(observation.operation, "model.construct") == 0;
    model_destructions +=
        std::strcmp(observation.operation, "model.destroy") == 0;
    require(observation.thread == model_thread,
            std::string("Wrong loading-worker thread: ") +
                observation.operation);
  }
  require(model_constructions == 1,
          "Original cleanup scope silently reloaded a new model");
  require(model_destructions == (script.fails_load ? 0U : 1U),
          "Model destroyed more than once or owner leaked");
}
void construct_model(const std::filesystem::path &model_directory) {
  observe_thread("model.construct");
  require(std::filesystem::is_directory(model_directory),
          "Non-directory reached model constructor");
  if (script.blocks_load.load()) {
    script.load_gate.block();
  } else {
  }
  if (script.fails_load) {
    throw std::runtime_error("PRIVATE model load path");
  } else {
  }
  ++script.live_models;
}
void destroy_model() noexcept {
  observe_thread("model.destroy");
  --script.live_models;
}
} // namespace native_test
namespace mlx::core {
void synchronize() {
  native_test::observe_thread("synchronize");
  const int sync_call = ++native_test::script.sync_count;
  if (native_test::script.blocks_sync.load()) {
    native_test::script.sync_gate.block();
  } else {
  }
  if (native_test::script.fail_sync_call == sync_call) {
    throw std::runtime_error("PRIVATE late GPU synchronize failure");
  } else if (native_test::script.sync_failures.load() > 0) {
    --native_test::script.sync_failures;
    throw std::runtime_error("PRIVATE GPU synchronize failure");
  } else {
  }
}
void clear_cache() {
  native_test::observe_thread("clear_cache");
  ++native_test::script.cache_count;
  if (native_test::script.cache_failures.load() > 0) {
    --native_test::script.cache_failures;
    throw std::runtime_error("PRIVATE cache cleanup failure");
  } else {
  }
}
} // namespace mlx::core
namespace moss {
MossTranscriber::MossTranscriber(const std::filesystem::path &model_directory) {
  native_test::construct_model(model_directory);
}
MossTranscriber::~MossTranscriber() { native_test::destroy_model(); }
qwen3_asr::TranscriptionResult
MossTranscriber::Transcribe(const std::vector<float> &samples,
                            const MossOptions &options,
                            const std::atomic<bool> &cancel) const {
  return native_test::script.decode(
      {{"operation", "Transcribe"},
       {"samples", samples},
       {"prompt", options.prompt ? nlohmann::json(*options.prompt)
                                 : nlohmann::json(nullptr)},
       {"max_new_tokens", options.max_new_tokens
                              ? nlohmann::json(*options.max_new_tokens)
                              : nlohmann::json(nullptr)},
       {"window_offset_seconds",
        options.window_offset_seconds
            ? nlohmann::json(*options.window_offset_seconds)
            : nlohmann::json(nullptr)},
       {"stop_at_end_of_text", options.stop_at_end_of_text},
       {"stop_on_token_loop", options.stop_on_token_loop}},
      cancel);
}
} // namespace moss
namespace nemotron {
NemotronTranscriber::NemotronTranscriber(
    const std::filesystem::path &model_directory) {
  native_test::construct_model(model_directory);
}
NemotronTranscriber::~NemotronTranscriber() { native_test::destroy_model(); }
NemotronStream::NemotronStream(const NemotronTranscriber &transcriber,
                               const NemotronOptions &options) {
  native_test::observe_thread("stream.construct");
  native_test::script.record(
      {{"operation", "Construct"},
       {"sampling_rate", transcriber.front_end().sampling_rate},
       {"frame_seconds", transcriber.frame_seconds()},
       {"language", options.language ? nlohmann::json(*options.language)
                                     : nlohmann::json(nullptr)},
       {"chunk_frames", options.chunk_frames
                            ? nlohmann::json(*options.chunk_frames)
                            : nlohmann::json(nullptr)}});
  if (native_test::script.fails_stream) {
    throw std::bad_alloc();
  } else {
  }
  ++native_test::script.live_streams;
}
NemotronStream::~NemotronStream() {
  native_test::observe_thread("stream.destroy");
  --native_test::script.live_streams;
}
void NemotronStream::Append(const std::vector<float> &samples,
                            const std::atomic<bool> &cancel) {
  ordered_samples.insert(ordered_samples.end(), samples.begin(), samples.end());
  last_result =
      native_test::script.decode({{"operation", "Append"},
                                  {"samples", samples},
                                  {"ordered_samples", ordered_samples}},
                                 cancel);
}
void NemotronStream::Finish(const std::vector<float> &samples,
                            const std::atomic<bool> &cancel) {
  ordered_samples.insert(ordered_samples.end(), samples.begin(), samples.end());
  last_result =
      native_test::script.decode({{"operation", "Finish"},
                                  {"samples", samples},
                                  {"ordered_samples", ordered_samples}},
                                 cancel);
}
std::string NemotronStream::Text() const {
  native_test::observe_thread("stream.Text");
  native_test::script.record(
      {{"operation", "Text"}, {"text", last_result.text}});
  return last_result.text;
}
qwen3_asr::TranscriptionResult NemotronStream::Result() const {
  native_test::observe_thread("stream.Result");
  native_test::script.record(
      {{"operation", "Result"}, {"text", last_result.text}});
  return last_result;
}
} // namespace nemotron
