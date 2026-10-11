// SPDX-License-Identifier: Apache-2.0
// Qwen realtime segmentation, refreshes and finalization without a transport.
#pragma once

#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "worker.h"

namespace qwen3_asr {

struct RealtimeSettings {
  int decode_interval_samples = 0;
  int first_decode_samples = 0;
  int max_segment_samples = 0;
};

RealtimeSettings MakeRealtimeSettings(int decode_interval_ms,
                                      int first_decode_ms,
                                      double max_segment_seconds);

// Join segment texts, with a space only between two spaced scripts.
std::string JoinTranscriptParts(const std::vector<std::string> &parts);

struct RealtimeUpdated {};
struct RealtimeSegment {
  int segment_id;
  std::string text;
  bool is_final;
};
struct RealtimeCompleted {
  std::string text;
};
struct RealtimeFailure {
  std::string type = "server_error";
  std::string code = "transcription_failed";
  std::string message = "Transcription failed.";
};
using RealtimeEvent = std::variant<RealtimeUpdated, RealtimeSegment,
                                   RealtimeCompleted, RealtimeFailure>;

// Create with shared ownership; serialize commands on one caller thread.
// Close may run concurrently. Worker/model must outlive the engine AND drain
// all queued/running work before model destruction; Close only cancels.
class RealtimeEngine : public std::enable_shared_from_this<RealtimeEngine> {
public:
  // Ordered on caller/worker threads; must not throw or reenter except Close.
  using EventSink = std::function<void(const RealtimeEvent &)>;

  RealtimeEngine(TranscriptionWorker &worker,
                 const Qwen3ASRTranscriber &transcriber,
                 RealtimeSettings settings, EventSink sink,
                 CancelFlag cancel = NewCancelFlag());
  ~RealtimeEngine();

  void UpdateLanguage(std::optional<std::string> language);
  // Mono samples at kSampleRate; empty input does nothing.
  void Append(std::vector<float> samples);
  void Commit();
  void Finish();
  void Close();

private:
  struct Segment {
    int segment_id = 0;
    long start_sample = 0;
    long next_refresh_sample = 0;
    std::optional<std::string> language;
    int decode_count = 0;
    std::string transcript;
    std::string last_text;
  };

  void Send(const RealtimeEvent &event);
  void ReportDecodeFailure(std::exception_ptr error);
  void StartSegment(long start_sample);
  long EndSample() const {
    return buffer_start_sample_ + static_cast<long>(samples_.size());
  }
  long LockedEndSample();
  std::vector<float> SegmentSamples(const Segment &segment,
                                    long end_sample) const;
  TranscriptionOptions DecodeOptions(Segment &segment);
  Transcription Decode(std::vector<float> samples,
                       TranscriptionOptions options) const;
  void ApplyResult(Segment &segment, const TranscriptionResult &result);
  void MaybeStartRefresh();
  void FinalizeThrough(long end_sample);

  TranscriptionWorker &worker_;
  const Qwen3ASRTranscriber &transcriber_;
  const RealtimeSettings settings_;
  EventSink sink_;
  CancelFlag cancel_;
  std::recursive_mutex send_mutex_;
  bool finished_ = false;

  std::mutex mutex_;
  std::condition_variable refresh_done_;
  std::optional<std::string> language_;
  std::vector<float> samples_;
  long buffer_start_sample_ = 0;
  std::optional<Segment> segment_;
  int next_segment_id_ = 0;
  std::vector<std::pair<int, std::string>> committed_;
  bool refreshing_ = false;
  bool finalizing_ = false;
};

} // namespace qwen3_asr
