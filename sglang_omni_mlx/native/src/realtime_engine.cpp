// SPDX-License-Identifier: Apache-2.0
#include "realtime_engine.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>

#include "audio.h"

namespace qwen3_asr {
namespace {

// Note (Jiaxin Deng): after two full re-decodes a refresh continues from the
// shown text minus its last tokens, which may still change.
constexpr int kPrefixAfterRefreshCount = 2;
constexpr int kPrefixRollbackTokenCount = 5;
constexpr float kSilentPeak = 1e-3f;
constexpr std::pair<uint32_t, uint32_t> kUnspacedScriptRanges[] = {
    {0x0E00, 0x0EFF}, {0x1000, 0x109F}, {0x1780, 0x17FF},
    {0x2E80, 0x303F}, {0x3040, 0x30FF}, {0x3400, 0x9FFF},
    {0xF900, 0xFAFF}, {0xFF00, 0xFFEF}, {0x20000, 0x2FA1F},
};

bool IsSpacedScript(uint32_t code_point) {
  if (IsUnicodeSpace(code_point)) {
    return false;
  } else {
  }
  for (const auto &[low, high] : kUnspacedScriptRanges) {
    if (code_point >= low && code_point <= high) {
      return false;
    } else {
    }
  }
  return true;
}

} // namespace

RealtimeSettings MakeRealtimeSettings(int decode_interval_ms,
                                      int first_decode_ms,
                                      double max_segment_seconds) {
  const int64_t decode_interval_samples =
      static_cast<int64_t>(decode_interval_ms) * kSampleRate / 1000;
  const int64_t first_decode_samples =
      static_cast<int64_t>(first_decode_ms) * kSampleRate / 1000;
  const double max_segment_samples = max_segment_seconds * kSampleRate;
  if (decode_interval_samples <= 0 || first_decode_samples <= 0 ||
      decode_interval_samples > std::numeric_limits<int>::max() ||
      first_decode_samples > std::numeric_limits<int>::max() ||
      !std::isfinite(max_segment_samples) || max_segment_samples < 1 ||
      max_segment_samples > std::numeric_limits<int>::max()) {
    throw std::invalid_argument("Invalid realtime settings.");
  } else {
    return {static_cast<int>(decode_interval_samples),
            static_cast<int>(first_decode_samples),
            static_cast<int>(max_segment_samples)};
  }
}

std::string JoinTranscriptParts(const std::vector<std::string> &parts) {
  std::string joined;
  for (const std::string &raw_part : parts) {
    const std::string part = StripUnicodeWhitespace(raw_part);
    if (part.empty()) {
      continue;
    } else if (!joined.empty() && IsSpacedScript(CodePoints(joined).back()) &&
               IsSpacedScript(CodePoints(part).front())) {
      joined += " " + part;
    } else {
      joined += part;
    }
  }
  return joined;
}

RealtimeEngine::RealtimeEngine(TranscriptionWorker &worker,
                               const Qwen3ASRTranscriber &transcriber,
                               RealtimeSettings settings, EventSink sink,
                               CancelFlag cancel,
                               TranscriptionOptions base_options)
    : worker_(worker), transcriber_(transcriber), settings_(settings),
      base_options_(std::move(base_options)), sink_(std::move(sink)),
      cancel_(std::move(cancel)), language_(base_options_.language) {
  if (settings_.decode_interval_samples <= 0 ||
      settings_.first_decode_samples <= 0 ||
      settings_.max_segment_samples <= 0) {
    throw std::invalid_argument("Invalid realtime settings.");
  } else {
  }
}

RealtimeEngine::~RealtimeEngine() { Close(); }

void RealtimeEngine::Send(const RealtimeEvent &event) {
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
  if (!cancel_->load()) {
    sink_(event);
  } else {
  }
}

void RealtimeEngine::Close() {
  {
    // Note (Codex): share the wait mutex so cancellation cannot lose its
    // wakeup.
    std::lock_guard<std::mutex> lock(mutex_);
    cancel_->store(true);
  }
  refresh_done_.notify_all();
  // Note (Codex): wait for an active sink, including when it calls Close.
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
}

void RealtimeEngine::ReportDecodeFailure(std::exception_ptr error) {
  try {
    std::rethrow_exception(error);
  } catch (const TranscriptionCancelled &) {
    return;
  } catch (const std::exception &failure) {
    // Note (Jiaxin Deng): log the type alone, never the audio or text.
    std::cerr << "realtime decode failed: " << typeid(failure).name() << "\n";
  } catch (...) {
    std::cerr << "realtime decode failed\n";
  }
  Send(failure_event_);
}

void RealtimeEngine::UpdateLanguage(std::optional<std::string> language) {
  if (finished_ || cancel_->load()) {
    return;
  } else {
    std::lock_guard<std::mutex> lock(mutex_);
    language_ =
        language.has_value() ? NormalizeLanguage(*language) : std::nullopt;
  }
  Send(RealtimeUpdated{});
}

void RealtimeEngine::Commit() {
  if (!finished_ && !cancel_->load()) {
    FinalizeThrough(LockedEndSample());
  } else {
  }
}

void RealtimeEngine::Finish() {
  if (finished_ || cancel_->load()) {
    return;
  } else {
  }
  FinalizeThrough(LockedEndSample());
  finished_ = true;
  std::vector<std::pair<int, std::string>> committed;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    committed = committed_;
  }
  std::sort(committed.begin(), committed.end());
  std::vector<std::string> texts;
  for (const auto &[segment_id, text] : committed)
    texts.push_back(text);
  Send(RealtimeCompleted{JoinTranscriptParts(texts)});
}

long RealtimeEngine::LockedEndSample() {
  std::lock_guard<std::mutex> lock(mutex_);
  return EndSample();
}

void RealtimeEngine::Append(std::vector<float> samples) {
  if (finished_ || cancel_->load() || samples.empty()) {
    return;
  } else {
  }
  long cut_sample = -1;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const long start_sample = EndSample();
    samples_.insert(samples_.end(), samples.begin(), samples.end());
    if (!segment_.has_value()) {
      StartSegment(start_sample);
    } else {
    }
    const long overflow =
        (EndSample() - segment_->start_sample) / settings_.max_segment_samples;
    if (overflow > 0) {
      cut_sample =
          segment_->start_sample + overflow * settings_.max_segment_samples;
    } else {
    }
  }
  if (cut_sample >= 0) {
    FinalizeThrough(cut_sample);
    std::lock_guard<std::mutex> lock(mutex_);
    StartSegment(cut_sample);
  } else {
  }
  MaybeStartRefresh();
}

void RealtimeEngine::StartSegment(long start_sample) {
  Segment segment;
  segment.segment_id = next_segment_id_++;
  segment.start_sample = start_sample;
  segment.next_refresh_sample = start_sample + settings_.first_decode_samples;
  segment.language = language_;
  segment_ = std::move(segment);
}

std::vector<float> RealtimeEngine::SegmentSamples(const Segment &segment,
                                                  long end_sample) const {
  const long begin = segment.start_sample - buffer_start_sample_;
  const long end = end_sample - buffer_start_sample_;
  return std::vector<float>(samples_.begin() + begin, samples_.begin() + end);
}

TranscriptionOptions RealtimeEngine::DecodeOptions(Segment &segment) {
  TranscriptionOptions options = base_options_;
  options.language = segment.language;
  const bool use_prefix = segment.decode_count >= kPrefixAfterRefreshCount &&
                          !segment.transcript.empty() &&
                          segment.language.has_value();
  if (use_prefix) {
    auto [ids, text] = transcriber_.RetainedPrefix(segment.transcript,
                                                   kPrefixRollbackTokenCount);
    options.prefix_token_ids = std::move(ids);
    options.prefix_text = std::move(text);
  } else {
  }
  segment.decode_count += 1;
  return options;
}

Transcription RealtimeEngine::Decode(std::vector<float> samples,
                                     TranscriptionOptions options) const {
  return [&transcriber = transcriber_, samples = std::move(samples),
          options = std::move(options)](const std::atomic<bool> &cancel) {
    return transcriber.Transcribe(samples, options, cancel);
  };
}

void RealtimeEngine::ApplyResult(Segment &segment,
                                 const TranscriptionResult &result) {
  if (result.language.has_value() && !result.language->empty()) {
    segment.language = result.language;
  } else {
  }
  segment.transcript = result.text;
}

void RealtimeEngine::MaybeStartRefresh() {
  std::vector<float> samples;
  TranscriptionOptions options;
  int segment_id = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (cancel_->load() || refreshing_ || finalizing_ ||
        !segment_.has_value() || EndSample() < segment_->next_refresh_sample) {
      return;
    } else {
    }
    Segment &segment = *segment_;
    const long end_sample = EndSample();
    samples = SegmentSamples(segment, end_sample);
    const bool silent =
        PeakIsSilent(samples.data(), samples.size(), kSilentPeak);
    // Note (Jiaxin Deng): leading silence keeps the early first decode for the
    // first audible audio.
    if (!(silent && segment.decode_count == 0)) {
      segment.next_refresh_sample =
          end_sample + settings_.decode_interval_samples;
    } else {
    }
    if (silent) {
      return;
    } else {
    }
    options = DecodeOptions(segment);
    segment_id = segment.segment_id;
    refreshing_ = true;
  }
  std::weak_ptr<RealtimeEngine> weak_self = shared_from_this();
  worker_.Submit(
      Decode(std::move(samples), std::move(options)), cancel_,
      [weak_self, segment_id](std::optional<TranscriptionResult> result,
                              std::exception_ptr error) {
        const std::shared_ptr<RealtimeEngine> self = weak_self.lock();
        if (!self) {
          return;
        } else {
        }
        try {
          std::optional<std::string> preview;
          {
            std::lock_guard<std::mutex> lock(self->mutex_);
            if (result.has_value() && self->segment_.has_value() &&
                self->segment_->segment_id == segment_id) {
              self->ApplyResult(*self->segment_, *result);
              if (result->text != self->segment_->last_text) {
                self->segment_->last_text = result->text;
                preview = result->text;
              } else {
              }
            } else {
            }
          }
          if (error) {
            self->ReportDecodeFailure(error);
          } else if (preview.has_value()) {
            self->Send(RealtimeSegment{segment_id, *preview, false});
          } else {
          }
          {
            // Note (Codex): finalization must not overtake preview publication.
            std::lock_guard<std::mutex> lock(self->mutex_);
            self->refreshing_ = false;
          }
          self->refresh_done_.notify_all();
          self->MaybeStartRefresh();
        } catch (...) {
          self->ReportDecodeFailure(std::current_exception());
          {
            std::lock_guard<std::mutex> lock(self->mutex_);
            self->refreshing_ = false;
          }
          self->refresh_done_.notify_all();
        }
      });
}

void RealtimeEngine::FinalizeThrough(long end_sample) {
  while (true) {
    Segment segment;
    std::vector<float> samples;
    long cut_sample = 0;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      if (cancel_->load() || !segment_.has_value() ||
          end_sample <= segment_->start_sample) {
        finalizing_ = false;
        return;
      } else {
      }
      // Note (Jiaxin Deng): wait out an in-flight preview and start no new one,
      // as the Python server's FIFO decode lock does.
      finalizing_ = true;
      refresh_done_.wait(lock, [&] { return !refreshing_ || cancel_->load(); });
      if (cancel_->load() || !segment_.has_value() ||
          end_sample <= segment_->start_sample) {
        finalizing_ = false;
        return;
      } else {
      }
      segment = *segment_;
      segment_.reset();
      cut_sample = std::min(end_sample, segment.start_sample +
                                            settings_.max_segment_samples);
      samples = SegmentSamples(segment, cut_sample);
    }
    std::optional<std::string> text;
    if (PeakIsSilent(samples.data(), samples.size(), kSilentPeak)) {
      text = std::string();
    } else {
      TranscriptionOptions options;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        options = DecodeOptions(segment);
      }
      try {
        const TranscriptionResult result = worker_.Transcribe(
            Decode(std::move(samples), std::move(options)), cancel_);
        ApplyResult(segment, result);
        text = result.text;
      } catch (...) {
        ReportDecodeFailure(std::current_exception());
      }
    }
    // Note (Jiaxin Deng): failed decodes are dropped rather than committed
    // empty.
    if (text.has_value()) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        committed_.emplace_back(segment.segment_id, *text);
      }
      Send(RealtimeSegment{segment.segment_id, *text, true});
    } else {
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      samples_.erase(samples_.begin(),
                     samples_.begin() + (cut_sample - buffer_start_sample_));
      buffer_start_sample_ = cut_sample;
      if (cut_sample < end_sample) {
        StartSegment(cut_sample);
      } else {
      }
    }
  }
}

} // namespace qwen3_asr
