// SPDX-License-Identifier: Apache-2.0
#include "nemotron_realtime_engine.h"

#include <array>
#include <cmath>
#include <iostream>
#include <utility>

namespace nemotron {

namespace {

// Note (Dayuxiaoshui): the live latency presets snap to the nearest chunk.
constexpr std::array<int, 5> kChunkMilliseconds = {80, 160, 320, 560, 1120};
// Note (Dayuxiaoshui): one day stays below the stream's int sample limit.
constexpr int64_t kMaxSessionSeconds = 24 * 60 * 60;

} // namespace

NemotronRealtimeEngine::NemotronRealtimeEngine(
    qwen3_asr::TranscriptionWorker &worker,
    const NemotronTranscriber &transcriber, EventSink event_sink,
    qwen3_asr::CancelFlag cancel)
    : worker_(worker), transcriber_(transcriber),
      event_sink_(std::move(event_sink)), cancel_(std::move(cancel)) {}

NemotronRealtimeEngine::~NemotronRealtimeEngine() { Close(); }

void NemotronRealtimeEngine::UpdateSettings(
    std::optional<std::string> language,
    std::optional<double> chunk_milliseconds) {
  std::unique_lock<std::mutex> lock(mutex_);
  if (cancel_->load()) {
    return;
  } else if (stream_ != nullptr) {
    lock.unlock();
    Emit(qwen3_asr::SpeakerRealtimeFailure{
        "invalid_request_error", "session_started",
        "Settings apply before the first audio."});
  } else if (chunk_milliseconds.has_value() && !(*chunk_milliseconds > 0)) {
    lock.unlock();
    Emit(qwen3_asr::SpeakerRealtimeFailure{
        "invalid_request_error", "invalid_chunk",
        "chunk_ms must be a positive number."});
  } else {
    options_.language = std::move(language);
    if (!chunk_milliseconds.has_value()) {
      options_.chunk_frames.reset();
    } else {
      const double requested = *chunk_milliseconds;
      int nearest = kChunkMilliseconds.front();
      for (const int candidate : kChunkMilliseconds) {
        if (std::abs(candidate - requested) < std::abs(nearest - requested)) {
          nearest = candidate;
        } else {
        }
      }
      options_.chunk_frames = static_cast<int>(
          std::lround(nearest / (transcriber_.frame_seconds() * 1000.0)));
    }
    lock.unlock();
    Emit(qwen3_asr::SpeakerRealtimeUpdated{});
  }
}

void NemotronRealtimeEngine::Append(std::vector<float> samples) {
  if (samples.empty()) {
    return;
  } else {
  }
  std::unique_lock<std::mutex> lock(mutex_);
  if (cancel_->load()) {
    return;
  } else if (finished_) {
    lock.unlock();
    Emit(qwen3_asr::SpeakerRealtimeFailure{
        "invalid_request_error", "session_finished",
        "The stream was committed; audio after it is not decoded."});
    return;
  } else if (failed_) {
    return;
  } else if (received_samples_ + static_cast<int64_t>(samples.size()) >
             kMaxSessionSeconds * transcriber_.front_end().sampling_rate) {
    lock.unlock();
    Emit(qwen3_asr::SpeakerRealtimeFailure{
        "invalid_request_error", "session_too_long",
        "A session takes at most 24 hours of audio."});
    return;
  } else {
  }
  try {
    pending_samples_.insert(pending_samples_.end(), samples.begin(),
                            samples.end());
    received_samples_ += static_cast<int64_t>(samples.size());
  } catch (...) {
    failed_ = true;
    lock.unlock();
    ReportDecodeFailure(std::current_exception());
    return;
  }
  if (!decoding_) {
    try {
      SubmitDecode(false);
    } catch (...) {
      lock.unlock();
      CompleteDecode(std::nullopt, std::current_exception(), false);
    }
  } else {
  }
}

void NemotronRealtimeEngine::PrepareStream() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!cancel_->load()) {
    EnsureStream();
  } else {
  }
}

void NemotronRealtimeEngine::EnsureStream() {
  if (stream_ == nullptr) {
    stream_ = std::make_shared<NemotronStream>(transcriber_, options_);
  } else {
  }
}

void NemotronRealtimeEngine::SubmitDecode(bool final) {
  decoding_ = true;
  EnsureStream();
  std::vector<float> samples = std::move(pending_samples_);
  pending_samples_.clear();
  const std::weak_ptr<NemotronRealtimeEngine> weak_self = shared_from_this();
  worker_.Submit(
      [stream = stream_, samples = std::move(samples),
       final](const std::atomic<bool> &cancel) {
        if (final) {
          stream->Finish(samples, cancel);
          return stream->Result();
        } else {
          stream->Append(samples, cancel);
          qwen3_asr::TranscriptionResult preview;
          preview.text = stream->Text();
          return preview;
        }
      },
      cancel_,
      [weak_self, final](std::optional<qwen3_asr::TranscriptionResult> result,
                         std::exception_ptr error) {
        if (const auto self = weak_self.lock()) {
          self->CompleteDecode(std::move(result), error, final);
        } else {
        }
      });
}

void NemotronRealtimeEngine::CompleteDecode(
    std::optional<qwen3_asr::TranscriptionResult> result,
    std::exception_ptr error, bool final) {
  bool submitted_next_decode = false;
  try {
    std::optional<qwen3_asr::SpeakerRealtimeEvent> event;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (error) {
        failed_ = true;
      } else if (final) {
        final_result_ = std::move(*result);
        event = qwen3_asr::SpeakerRealtimeSegment{0, final_result_.text, true,
                                                  final_result_.segments};
      } else if (!result->text.empty() && result->text != shown_text_) {
        shown_text_ = result->text;
        event = qwen3_asr::SpeakerRealtimeSegment{0, result->text, false};
      } else {
      }
      // Note (Codex): preserve the pending batch before a slow sink runs.
      if (!cancel_->load() && !failed_ && !finished_ &&
          !pending_samples_.empty()) {
        SubmitDecode(false);
        submitted_next_decode = true;
      } else {
      }
    }
    if (error) {
      ReportDecodeFailure(error);
    } else if (event.has_value()) {
      Emit(*event);
    } else {
    }
  } catch (...) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      failed_ = true;
    }
    ReportDecodeFailure(std::current_exception());
  }

  // Note (Codex): Finish must not overtake a preview still inside its sink.
  std::unique_lock<std::mutex> lock(mutex_);
  if (submitted_next_decode) {
    return;
  } else if (!cancel_->load() && !failed_ && !finished_ &&
             !pending_samples_.empty()) {
    try {
      SubmitDecode(false);
      return;
    } catch (...) {
      failed_ = true;
      lock.unlock();
      ReportDecodeFailure(std::current_exception());
      lock.lock();
    }
  } else {
  }
  decoding_ = false;
  lock.unlock();
  decode_done_.notify_all();
}

void NemotronRealtimeEngine::Commit() {
  std::unique_lock<std::mutex> lock(mutex_);
  decode_done_.wait(lock, [&] { return !decoding_ || cancel_->load(); });
  if (cancel_->load()) {
    return;
  } else if (finished_ || failed_) {
    finished_ = true;
    return;
  } else {
  }
  finished_ = true;
  try {
    SubmitDecode(true);
  } catch (...) {
    lock.unlock();
    CompleteDecode(std::nullopt, std::current_exception(), true);
    return;
  }
  decode_done_.wait(lock, [&] { return !decoding_ || cancel_->load(); });
}

void NemotronRealtimeEngine::Finish() {
  Commit();
  try {
    std::unique_lock<std::mutex> lock(mutex_);
    if (cancel_->load() || completed_) {
      return;
    } else {
    }
    completed_ = true;
    const qwen3_asr::SpeakerRealtimeCompleted event{final_result_.text,
                                                    final_result_.segments};
    lock.unlock();
    Emit(event);
  } catch (...) {
    ReportDecodeFailure(std::current_exception());
  }
}

void NemotronRealtimeEngine::Emit(
    const qwen3_asr::SpeakerRealtimeEvent &event) {
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
  if (cancel_->load()) {
    return;
  } else {
  }
  try {
    event_sink_(event);
  } catch (...) {
    // Note (Codex): a broken sink must not strand Finish or kill the worker.
    std::cerr << "realtime event sink failed\n";
    Close();
  }
}

void NemotronRealtimeEngine::ReportDecodeFailure(
    std::exception_ptr error) noexcept {
  try {
    std::rethrow_exception(error);
  } catch (const qwen3_asr::TranscriptionCancelled &) {
    return;
  } catch (const std::exception &failure) {
    std::cerr << "realtime decode failed: " << typeid(failure).name() << "\n";
  } catch (...) {
    std::cerr << "realtime decode failed\n";
  }
  try {
    Emit(qwen3_asr::SpeakerRealtimeFailure{});
  } catch (...) {
    Close();
  }
}

void NemotronRealtimeEngine::Close() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cancel_->store(true);
  }
  decode_done_.notify_all();
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
}

} // namespace nemotron
