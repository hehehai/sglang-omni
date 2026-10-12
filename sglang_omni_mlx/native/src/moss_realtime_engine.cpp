// SPDX-License-Identifier: Apache-2.0
#include "moss_realtime_engine.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>

#include "audio.h"

namespace moss {

using qwen3_asr::kSampleRate;
using qwen3_asr::SpeakerRealtimeCompleted;
using qwen3_asr::SpeakerRealtimeFailure;
using qwen3_asr::SpeakerRealtimeSegment;
using qwen3_asr::SpeakerRealtimeUpdated;
using qwen3_asr::StripUnicodeWhitespace;
using qwen3_asr::TranscriptionResult;

namespace {

// Note (Dayuxiaoshui): Voxt's Swift session: 4 s windows, and at most one
// preview a second of the last 2.5 s pending, once 1.25 s has arrived.
constexpr int kWindowSamples = 4 * kSampleRate;
constexpr int kPreviewSamples = kSampleRate * 5 / 2;
constexpr int kMinPreviewSamples = kSampleRate * 5 / 4;
constexpr auto kPreviewInterval = std::chrono::seconds(1);
// Note (Dayuxiaoshui): Voxt's intermediate budget, scaled by window length; a
// preview gets half a final window's, since it is decoded again.
constexpr int kMaxTokensPerPass = 1024;
constexpr double kPreviewTokensPerSecond = 16.0;
constexpr int kMinPreviewTokens = 48;
constexpr double kFinalTokensPerSecond = 32.0;
constexpr int kMinFinalTokens = 96;

} // namespace

MossRealtimeEngine::MossRealtimeEngine(qwen3_asr::TranscriptionWorker &worker,
                                       const MossTranscriber &transcriber,
                                       EventSink sink,
                                       qwen3_asr::CancelFlag cancel)
    : worker_(worker), transcriber_(transcriber), sink_(std::move(sink)),
      cancel_(std::move(cancel)) {}

MossRealtimeEngine::~MossRealtimeEngine() { Close(); }

void MossRealtimeEngine::Send(
    const qwen3_asr::SpeakerRealtimeEvent &event) noexcept {
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
  if (cancel_->load()) {
    return;
  } else {
  }
  try {
    sink_(event);
  } catch (...) {
    // Note (OpenAI): a broken sink must not escape the worker callback.
    std::fputs("realtime event sink failed\n", stderr);
    Close();
  }
}

void MossRealtimeEngine::Close() {
  {
    // Note (OpenAI): cancellation shares the wait mutex to avoid a lost wakeup.
    std::lock_guard<std::mutex> lock(mutex_);
    cancel_->store(true);
  }
  decode_done_.notify_all();
  // Note (OpenAI): wait for delivery, not decoding; a sink may itself Close.
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
}

void MossRealtimeEngine::ReportDecodeFailure(
    std::exception_ptr error) noexcept {
  try {
    std::rethrow_exception(error);
  } catch (const qwen3_asr::TranscriptionCancelled &) {
    return;
  } catch (const std::exception &failure) {
    // Note (Jiaxin Deng): log the type alone, never the audio or text.
    std::fprintf(stderr, "realtime decode failed: %s\n",
                 typeid(failure).name());
  } catch (...) {
    std::fputs("realtime decode failed\n", stderr);
  }
  Send(failure_event_);
}

void MossRealtimeEngine::UpdatePrompt(std::optional<std::string> prompt) {
  if (finished_ || cancel_->load()) {
    return;
  } else {
  }
  try {
    ValidatePrompt(prompt);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      prompt_ = std::move(prompt);
    }
    Send(SpeakerRealtimeUpdated{});
  } catch (const std::invalid_argument &) {
    Send(SpeakerRealtimeFailure{
        "invalid_request_error", "invalid_prompt",
        "prompt must carry at most one <|audio_pad|> placeholder"});
  } catch (...) {
    ReportDecodeFailure(std::current_exception());
  }
}

void MossRealtimeEngine::Append(std::vector<float> samples) {
  if (finished_ || cancel_->load() || samples.empty()) {
    return;
  } else {
  }
  std::optional<Decode> decode;
  try {
    MossOptions options;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending_samples_.insert(pending_samples_.end(), samples.begin(),
                              samples.end());
      decode = NextDecode();
      if (decode.has_value()) {
        options = DecodeOptions(*decode);
      } else {
        return;
      }
    }
    SubmitDecode(std::move(*decode), std::move(options));
  } catch (...) {
    ReportDecodeFailure(std::current_exception());
    if (decode.has_value()) {
      EndDecode();
    } else {
    }
  }
}

MossRealtimeEngine::Decode
MossRealtimeEngine::TakeFinalWindow(int sample_count) {
  Decode decode;
  decode.kind = DecodeKind::kFinal;
  decode.samples.assign(pending_samples_.begin(),
                        pending_samples_.begin() + sample_count);
  decode.window_id = next_window_id_++;
  decode.offset_seconds =
      static_cast<double>(pending_start_sample_) / kSampleRate;
  pending_samples_.erase(pending_samples_.begin(),
                         pending_samples_.begin() + sample_count);
  pending_start_sample_ += sample_count;
  return decode;
}

std::optional<MossRealtimeEngine::Decode> MossRealtimeEngine::NextDecode() {
  const auto now = std::chrono::steady_clock::now();
  const int pending_count = static_cast<int>(pending_samples_.size());
  Decode decode;
  if (decoding_ || cancel_->load()) {
    return std::nullopt;
  } else if (pending_count >= kWindowSamples) {
    decode = TakeFinalWindow(kWindowSamples);
  } else if (pending_count < kMinPreviewSamples ||
             (last_decode_time_.has_value() &&
              now - *last_decode_time_ < kPreviewInterval)) {
    return std::nullopt;
  } else {
    const int preview_count = std::min(pending_count, kPreviewSamples);
    const int preview_start = pending_count - preview_count;
    decode.kind = DecodeKind::kPreview;
    decode.window_id = next_window_id_;
    decode.samples.assign(pending_samples_.begin() + preview_start,
                          pending_samples_.end());
    decode.offset_seconds =
        static_cast<double>(pending_start_sample_ + preview_start) /
        kSampleRate;
  }
  decoding_ = true;
  last_decode_time_ = now;
  return decode;
}

MossOptions MossRealtimeEngine::DecodeOptions(const Decode &decode) const {
  const double seconds =
      static_cast<double>(decode.samples.size()) / kSampleRate;
  MossOptions options;
  options.prompt = prompt_;
  options.window_offset_seconds = decode.offset_seconds;
  // Note (Dayuxiaoshui): Voxt's Swift session always applied both stops.
  options.stop_at_end_of_text = true;
  options.stop_on_token_loop = true;
  options.max_new_tokens =
      decode.kind == DecodeKind::kPreview
          ? std::min(kMaxTokensPerPass,
                     std::max(kMinPreviewTokens,
                              static_cast<int>(std::ceil(
                                  seconds * kPreviewTokensPerSecond))))
          : std::min(kMaxTokensPerPass,
                     std::max(kMinFinalTokens,
                              static_cast<int>(
                                  std::ceil(seconds * kFinalTokensPerSecond))));
  return options;
}

void MossRealtimeEngine::SubmitDecode(Decode decode, MossOptions options) {
  qwen3_asr::Transcription job =
      [&transcriber = transcriber_, samples = decode.samples,
       options = std::move(options)](const std::atomic<bool> &cancel) {
        return transcriber.Transcribe(samples, options, cancel);
      };
  std::weak_ptr<MossRealtimeEngine> weak_self = shared_from_this();
  worker_.Submit(
      std::move(job), cancel_,
      [weak_self, decode = std::move(decode)](
          std::optional<TranscriptionResult> result, std::exception_ptr error) {
        const std::shared_ptr<MossRealtimeEngine> self = weak_self.lock();
        if (!self) {
          return;
        } else {
        }
        try {
          if (error) {
            self->ReportDecodeFailure(error);
          } else {
            self->Publish(decode, *result);
          }
        } catch (...) {
          self->ReportDecodeFailure(std::current_exception());
        }
        self->EndDecode();
      });
}

void MossRealtimeEngine::Publish(const Decode &decode,
                                 const TranscriptionResult &result) {
  const std::string text = StripUnicodeWhitespace(result.text);
  if (decode.kind == DecodeKind::kPreview) {
    // Note (Dayuxiaoshui): an empty preview clears the one on screen.
    Send(SpeakerRealtimeSegment{decode.window_id, text, false});
    return;
  } else {
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!text.empty()) {
      committed_texts_.push_back(text);
    } else {
    }
    committed_segments_.insert(committed_segments_.end(),
                               result.segments.begin(), result.segments.end());
  }
  Send(SpeakerRealtimeSegment{decode.window_id, text, true, result.segments});
}

void MossRealtimeEngine::EndDecode() {
  {
    // Note (OpenAI): keep the decode barrier until event delivery finishes.
    std::lock_guard<std::mutex> lock(mutex_);
    decoding_ = false;
  }
  decode_done_.notify_all();
}

void MossRealtimeEngine::Commit() {
  if (!finished_ && !cancel_->load()) {
    Flush();
  } else {
  }
}

void MossRealtimeEngine::Finish() {
  if (finished_ || cancel_->load()) {
    return;
  } else {
  }
  Flush();
  finished_ = true;
  try {
    SpeakerRealtimeCompleted completed;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (const std::string &part : committed_texts_) {
        completed.text += (completed.text.empty() ? "" : "\n") + part;
      }
      completed.segments = committed_segments_;
    }
    Send(completed);
  } catch (...) {
    ReportDecodeFailure(std::current_exception());
  }
}

void MossRealtimeEngine::Flush() {
  while (true) {
    Decode decode;
    MossOptions options;
    try {
      std::unique_lock<std::mutex> lock(mutex_);
      decode_done_.wait(lock, [&] { return !decoding_ || cancel_->load(); });
      const int pending_count = static_cast<int>(pending_samples_.size());
      if (cancel_->load() || pending_count == 0) {
        return;
      } else if (pending_count >= 2 * kWindowSamples) {
        // Note (Dayuxiaoshui): split a backlog to keep its tail in budget.
        decode = TakeFinalWindow(kWindowSamples);
      } else {
        // Note (Dayuxiaoshui): as Swift ended, the rest is under two windows.
        decode = TakeFinalWindow(pending_count);
      }
      options = DecodeOptions(decode);
      decoding_ = true;
    } catch (...) {
      ReportDecodeFailure(std::current_exception());
      return;
    }
    try {
      // Note (OpenAI): the loop's cancel-aware wait must also cover final jobs.
      SubmitDecode(std::move(decode), std::move(options));
    } catch (...) {
      ReportDecodeFailure(std::current_exception());
      EndDecode();
    }
  }
}

} // namespace moss
