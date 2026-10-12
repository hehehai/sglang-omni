// SPDX-License-Identifier: Apache-2.0
// MOSS realtime windows, previews and finalization without a transport.
#pragma once

#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "moss_transcriber.h"
#include "speaker_realtime_event.h"
#include "worker.h"

namespace moss {

// Create with shared ownership; serialize commands on one caller thread.
// Close may run concurrently, but destruction may not. Worker/transcriber/model
// must outlive the engine AND drain queued work before destruction; Close
// cancels.
class MossRealtimeEngine
    : public std::enable_shared_from_this<MossRealtimeEngine> {
public:
  // Ordered on caller/worker threads; must not throw or reenter except Close.
  using EventSink =
      std::function<void(const qwen3_asr::SpeakerRealtimeEvent &)>;

  MossRealtimeEngine(qwen3_asr::TranscriptionWorker &worker,
                     const MossTranscriber &transcriber, EventSink sink,
                     qwen3_asr::CancelFlag cancel = qwen3_asr::NewCancelFlag());
  ~MossRealtimeEngine();

  void UpdatePrompt(std::optional<std::string> prompt);
  // Mono samples at kSampleRate; empty input does nothing.
  void Append(std::vector<float> samples);
  void Commit();
  void Finish();
  void Close();

private:
  enum class DecodeKind { kPreview, kFinal };

  struct Decode {
    DecodeKind kind = DecodeKind::kPreview;
    int window_id = 0;
    std::vector<float> samples;
    double offset_seconds = 0.0;
  };

  void Send(const qwen3_asr::SpeakerRealtimeEvent &event) noexcept;
  void ReportDecodeFailure(std::exception_ptr error) noexcept;
  std::optional<Decode> NextDecode();
  Decode TakeFinalWindow(int sample_count);
  MossOptions DecodeOptions(const Decode &decode) const;
  void SubmitDecode(Decode decode, MossOptions options);
  void Publish(const Decode &decode,
               const qwen3_asr::TranscriptionResult &result);
  void EndDecode();
  void Flush();

  qwen3_asr::TranscriptionWorker &worker_;
  const MossTranscriber &transcriber_;
  // Note (OpenAI): reporting an allocation failure must not allocate again.
  const qwen3_asr::SpeakerRealtimeEvent failure_event_ =
      qwen3_asr::SpeakerRealtimeFailure{};
  EventSink sink_;
  qwen3_asr::CancelFlag cancel_;
  std::recursive_mutex send_mutex_;
  bool finished_ = false;

  std::mutex mutex_;
  std::condition_variable decode_done_;
  std::optional<std::string> prompt_;
  std::vector<float> pending_samples_;
  long pending_start_sample_ = 0;
  int next_window_id_ = 0;
  bool decoding_ = false;
  std::optional<std::chrono::steady_clock::time_point> last_decode_time_;
  std::vector<std::string> committed_texts_;
  std::vector<qwen3_asr::SpeakerSegment> committed_segments_;
};

} // namespace moss
