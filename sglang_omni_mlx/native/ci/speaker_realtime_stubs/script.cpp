// SPDX-License-Identifier: Apache-2.0
#include "moss_transcriber.h"
#include "nemotron_transcriber.h"

namespace speaker_test {
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
          "Timed out releasing barrier");
}
void Gate::wait() {
  std::unique_lock<std::mutex> lock(mutex);
  require(changed.wait_for(lock, TIMEOUT_SECONDS, [&] { return entered; }),
          "Timed out entering barrier");
}
void Gate::release() {
  std::lock_guard<std::mutex> lock(mutex);
  released = true;
  changed.notify_all();
}
void DecodeScript::record(nlohmann::ordered_json call) {
  std::lock_guard<std::mutex> lock(mutex);
  calls.push_back(std::move(call));
}
nlohmann::ordered_json DecodeScript::snapshot() {
  std::lock_guard<std::mutex> lock(mutex);
  return calls;
}
qwen3_asr::TranscriptionResult
DecodeScript::decode(nlohmann::ordered_json call,
                     const std::atomic<bool> &cancel) {
  std::unique_lock<std::mutex> lock(mutex);
  const DecodeStep step = steps.at(decode_count++);
  const size_t call_index = calls.size();
  call["cancelled_at_entry"] = cancel.load();
  call["result"] = {
      {"text", step.result.text},
      {"language", step.result.language ? nlohmann::json(*step.result.language)
                                        : nlohmann::json(nullptr)},
      {"generated_token_count", step.result.generated_token_count},
      {"finish_reason",
       step.result.finish_reason == qwen3_asr::FinishReason::kStop ? "stop"
                                                                   : "length"},
      {"segments", qwen3_asr::SpeakerSegmentsJson(step.result.segments)}};
  calls.push_back(std::move(call));
  lock.unlock();
  if (step.is_blocked) {
    model_gate.block();
  } else {
  }
  lock.lock();
  calls[call_index]["cancelled_at_return"] = cancel.load();
  if (cancel.load() && !step.ignores_cancellation) {
    throw qwen3_asr::TranscriptionCancelled();
  } else if (throws_bad_alloc) {
    throw std::bad_alloc();
  } else if (step.should_fail) {
    throw std::runtime_error("PRIVATE model/audio/path/transcript failure");
  } else {
    return step.result;
  }
}
qwen3_asr::TranscriptionResult result(const std::string &text,
                                      double offset_seconds) {
  return {text,
          "result-language",
          7,
          qwen3_asr::FinishReason::kStop,
          {{offset_seconds + 0.125, offset_seconds + 0.875, "S03", text,
            "en-US", "neutral", "speech"},
           {offset_seconds + 0.875, offset_seconds + 1.0, "", "tail",
            std::nullopt, std::nullopt, std::nullopt}}};
}
} // namespace speaker_test

namespace moss {
qwen3_asr::TranscriptionResult
MossTranscriber::Transcribe(const std::vector<float> &samples,
                            const MossOptions &options,
                            const std::atomic<bool> &cancel) const {
  return script_.decode(
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
void ValidatePrompt(const std::optional<std::string> &prompt) {
  const std::string instruction = prompt.value_or("");
  const std::string placeholder = "<|audio_pad|>";
  const size_t first = instruction.find(placeholder);
  if (first != std::string::npos &&
      instruction.find(placeholder, first + placeholder.size()) !=
          std::string::npos) {
    throw std::invalid_argument(
        "prompt must carry at most one <|audio_pad|> placeholder");
  } else {
  }
}
} // namespace moss

namespace nemotron {
NemotronStream::NemotronStream(const NemotronTranscriber &transcriber,
                               const NemotronOptions &options)
    : script_(transcriber.script), stream_id_(script_.next_stream_id++) {
  script_.record(
      {{"operation", "Construct"},
       {"stream_id", stream_id_},
       {"sampling_rate", transcriber.front_end().sampling_rate},
       {"frame_seconds", transcriber.frame_seconds()},
       {"language", options.language ? nlohmann::json(*options.language)
                                     : nlohmann::json(nullptr)},
       {"chunk_frames", options.chunk_frames
                            ? nlohmann::json(*options.chunk_frames)
                            : nlohmann::json(nullptr)}});
  if (script_.fails_construction) {
    throw std::bad_alloc();
  } else {
  }
}
void NemotronStream::Append(const std::vector<float> &samples,
                            const std::atomic<bool> &cancel) {
  ordered_samples_.insert(ordered_samples_.end(), samples.begin(),
                          samples.end());
  result_ = script_.decode({{"operation", "Append"},
                            {"stream_id", stream_id_},
                            {"samples", samples},
                            {"ordered_samples", ordered_samples_}},
                           cancel);
}
void NemotronStream::Finish(const std::vector<float> &samples,
                            const std::atomic<bool> &cancel) {
  ordered_samples_.insert(ordered_samples_.end(), samples.begin(),
                          samples.end());
  result_ = script_.decode({{"operation", "Finish"},
                            {"stream_id", stream_id_},
                            {"samples", samples},
                            {"ordered_samples", ordered_samples_}},
                           cancel);
}
std::string NemotronStream::Text() const {
  script_.record({{"operation", "Text"},
                  {"stream_id", stream_id_},
                  {"text", result_.text}});
  return result_.text;
}
qwen3_asr::TranscriptionResult NemotronStream::Result() const {
  script_.record({{"operation", "Result"},
                  {"stream_id", stream_id_},
                  {"text", result_.text}});
  return result_;
}
} // namespace nemotron
